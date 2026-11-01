import Foundation
import PDFKit

/// Native OCG edits on an immutable, CURRENT-session snapshot. Never writes the
/// source, never uses annotation membership to simulate drawing-layer visibility.
/// The caller must adopt the result as an undoable session transaction and retain
/// Output for as long as PDFKit may lazily read its backing file.
enum NativePDFLayerMutation {
    enum Operation: Sendable { case visibility(Bool), deleteContent }
    enum Failure: LocalizedError {
        case unsupported(String), invalid
        var errorDescription: String? {
            switch self {
            case .unsupported(let detail): return "This PDF layer cannot be edited safely: \(detail). No drawing or source file was changed."
            case .invalid: return "The PDF layer or helper output was invalid. No drawing or source file was changed."
            }
        }
    }
    final class Output: @unchecked Sendable {
        let url: URL
        private let directory: URL
        init(url: URL, directory: URL) { self.url = url; self.directory = directory }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }
    private static func run(_ helper: URL, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = helper; process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        // Mutation/check warnings are deliberately not treated as verified success.
        guard process.terminationStatus == 0 else { throw Failure.invalid }
    }
    static func transform(source: URL, registryIndex: Int, operation: Operation,
                          helper: URL? = PDFTKBookmarkWriter.executableURL()) throws -> Output {
        guard let helper else { throw Failure.unsupported("qpdf is unavailable") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeNativeLayers-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: directory) } }
        let frozen = directory.appendingPathComponent("snapshot.pdf")
        let jsonURL = directory.appendingPathComponent("edit.json")
        let candidate = directory.appendingPathComponent("edited.pdf")
        // No original path is ever passed as a qpdf output, even on failure.
        try FileManager.default.copyItem(at: source, to: frozen)
        var json = try PDFLayerPurger.inspect(frozen, helper: helper)
        guard (json["encrypt"] as? [String: Any])?["encrypted"] as? Bool != true,
              var tables = json["qpdf"] as? [[String: Any]], tables.count == 2 else { throw Failure.invalid }
        var graph = tables[1]
        func resolve(_ value: Any?) -> Any? {
            if let ref = value as? String, let object = graph["obj:" + ref] as? [String: Any] { return object["value"] }
            return value
        }
        func dictionary(_ value: Any?) -> [String: Any]? { resolve(value) as? [String: Any] }
        guard let trailer = (graph["trailer"] as? [String: Any])?["value"] as? [String: Any],
              let rootRef = trailer["/Root"] as? String,
              var root = dictionary(rootRef), let propertiesValue = root["/OCProperties"],
              var properties = dictionary(propertiesValue), let groups = resolve(properties["/OCGs"]) as? [String],
              groups.indices.contains(registryIndex), let selected = dictionary(groups[registryIndex]),
              selected["/Type"] as? String == "/OCG", selected["/DrawbridgeLayerID"] == nil,
              let defaultValue = properties["/D"], var defaults = dictionary(defaultValue) else { throw Failure.invalid }
        let target = groups[registryIndex]
        let registered = Set(groups)
        guard defaults["/AS"] == nil, properties["/Configs"] == nil,
              ["/ON", "/OFF"].contains(defaults["/BaseState"] as? String ?? "/ON"),
              (resolve(defaults["/RBGroups"]) as? [Any] ?? []).isEmpty else {
            throw Failure.unsupported("automatic, alternate, radio-button or inherited visibility configurations")
        }
        for entry in graph.values {
            let object = entry as? [String: Any] ?? [:]
            let dict = object["value"] as? [String: Any] ?? (object["stream"] as? [String: Any])?["dict"] as? [String: Any] ?? [:]
            if dict["/Type"] as? String == "/OCMD" { throw Failure.unsupported("optional-content membership expressions (OCMD)") }
            if dict["/Type"] as? String == "/Sig" || dict["/FT"] as? String == "/Sig" { throw Failure.unsupported("digital signatures") }
        }
        func replaceDictionary(_ original: Any, with value: [String: Any]) -> Any {
            if let ref = original as? String, graph["obj:" + ref] != nil {
                graph["obj:" + ref] = ["value": value]; return ref
            }
            return value
        }
        switch operation {
        case .visibility(let visible):
            // Explicit ON/OFF wins over BaseState. Keep every other group's state.
            for key in ["/ON", "/OFF"] {
                guard defaults[key] == nil || resolve(defaults[key]) is [String] else { throw Failure.invalid }
                var values = (resolve(defaults[key]) as? [String] ?? []).filter { $0 != target }
                if (key == "/ON") == visible { values.append(target) }
                defaults[key] = values
            }
            // Usage may independently override the default in a viewer. Rather than
            // silently promise visibility, this bounded path rejects that case.
            if let usageValue = selected["/Usage"] {
                guard let usage = dictionary(usageValue), Set(usage.keys).isSubset(of: ["/CreatorInfo"]) else {
                    throw Failure.unsupported("layer Usage overrides")
                }
            }
            properties["/D"] = replaceDictionary(defaultValue, with: defaults)
            root["/OCProperties"] = replaceDictionary(propertiesValue, with: properties)
            graph["obj:" + rootRef] = ["value": root]
        case .deleteContent:
            // CharProcs execute drawing programs outside the page/Form walker.
            // Reject direct as well as indirect Type3 font dictionaries rather
            // than report success while leaving glyph-local layer paint intact.
            func containsType3(_ value: Any) -> Bool {
                if let dict = value as? [String: Any] {
                    return dict["/Subtype"] as? String == "/Type3" || dict.values.contains(where: containsType3)
                }
                if let array = value as? [Any] { return array.contains(where: containsType3) }
                return false
            }
            guard !containsType3(graph) else { throw Failure.unsupported("Type3 glyph programs") }
            // Keep the native group as an empty registry entry. This is NOT Purge:
            // painting operators/invocations disappear while state operators remain,
            // so unrelated later paths retain their original color/transform/clip.
            var programs: [String: ([String: Bool], [String: Bool])] = [:]
            func resourceMaps(_ resourceValue: Any?) throws -> ([String: Bool], [String: Bool]) {
                guard resourceValue != nil else { return ([:], [:]) }
                guard let resources = dictionary(resourceValue) else { throw Failure.invalid }
                var oc: [String: Bool] = [:], xObjects: [String: Bool] = [:]
                if let values = resources["/Properties"] {
                    guard let items = dictionary(values) else { throw Failure.invalid }
                    for (name, value) in items {
                        if let ref = value as? String, registered.contains(ref) { oc[name] = ref == target }
                        else if dictionary(value)?["/Type"] as? String == "/OCG" || dictionary(value)?["/Type"] as? String == "/OCMD" {
                            throw Failure.unsupported("unregistered or direct optional-content groups")
                        }
                    }
                }
                if let values = resources["/XObject"] {
                    guard let items = dictionary(values) else { throw Failure.invalid }
                    for (name, value) in items {
                        guard let ref = value as? String,
                              let stream = (graph["obj:" + ref] as? [String: Any])?["stream"] as? [String: Any],
                              let dict = stream["dict"] as? [String: Any] else { throw Failure.invalid }
                        if let membership = dict["/OC"] {
                            guard let group = membership as? String, registered.contains(group) else { throw Failure.unsupported("complex XObject membership") }
                            xObjects[name] = group == target
                        } else { xObjects[name] = false }
                    }
                }
                return (oc, xObjects)
            }
            func addProgram(_ ref: String, resources: Any?) throws {
                guard let stream = (graph["obj:" + ref] as? [String: Any])?["stream"] as? [String: Any],
                      let dict = stream["dict"] as? [String: Any], dict["/Filter"] == nil else { throw Failure.unsupported("undecodable drawing stream") }
                let maps = try resourceMaps(resources)
                if let old = programs[ref], old.0 != maps.0 || old.1 != maps.1 { throw Failure.unsupported("shared streams with differing resource scopes") }
                programs[ref] = maps
            }
            // Page resources can be inherited. Cycles and missing ancestors reject.
            func pageResources(_ page: [String: Any]) throws -> Any? {
                var current = page, visited = Set<String>()
                while current["/Resources"] == nil, let parent = current["/Parent"] as? String {
                    guard visited.insert(parent).inserted, let next = dictionary(parent) else { throw Failure.invalid }
                    current = next
                }
                return current["/Resources"]
            }
            for (key, value) in graph {
                let object = value as? [String: Any] ?? [:]
                if let dict = object["value"] as? [String: Any] {
                    if dict["/OC"] as? String == target { throw Failure.unsupported("layer-associated annotations or non-stream objects") }
                    if dict["/Type"] as? String == "/Page", let contents = dict["/Contents"] {
                        let refs: [String]
                        if let array = resolve(contents) as? [String] { refs = array }
                        else if let ref = contents as? String { refs = [ref] }
                        else { throw Failure.invalid }
                        // Cross-stream operands/scopes need concatenation and a new
                        // per-page stream. Do not reinterpret each in isolation.
                        guard refs.count == 1 else { throw Failure.unsupported("multi-stream page programs") }
                        try addProgram(refs[0], resources: pageResources(dict))
                    }
                }
                if let stream = object["stream"] as? [String: Any], let dict = stream["dict"] as? [String: Any] {
                    if dict["/PatternType"] != nil { throw Failure.unsupported("tiling-pattern programs") }
                    if dict["/Subtype"] as? String == "/Form" {
                        // A form whose own OC is selected is removed at its Do sites;
                        // its unused bytes are retained as resources, not executed.
                        if dict["/OC"] as? String != target {
                            guard dict["/Resources"] != nil else { throw Failure.unsupported("forms with caller-inherited resources") }
                            try addProgram(String(key.dropFirst(4)), resources: dict["/Resources"])
                        }
                    }
                }
            }
            for (ref, maps) in programs {
                guard var object = graph["obj:" + ref] as? [String: Any],
                      var stream = object["stream"] as? [String: Any],
                      let encoded = stream["data"] as? String, let bytes = Data(base64Encoded: encoded) else { throw Failure.invalid }
                let edited = try removingPaint(bytes, properties: maps.0, xObjects: maps.1)
                stream["data"] = edited.base64EncodedString(); object["stream"] = stream; graph["obj:" + ref] = object
            }
        }
        tables[1] = graph; json["qpdf"] = tables
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: jsonURL)
        try run(helper, [frozen.path, "--update-from-json=" + jsonURL.path, "--stream-data=preserve", candidate.path])
        try run(helper, ["--check", candidate.path])
        guard let before = CGPDFDocument(frozen as CFURL), let after = CGPDFDocument(candidate as CFURL), before.numberOfPages == after.numberOfPages else { throw Failure.invalid }
        for index in 1...before.numberOfPages {
            guard let a = before.page(at: index), let b = after.page(at: index), a.rotationAngle == b.rotationAngle else { throw Failure.invalid }
            for box in [CGPDFBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
                guard a.getBoxRect(box) == b.getBoxRect(box) else { throw Failure.invalid }
            }
        }
        completed = true; return Output(url: candidate, directory: directory)
    }

    /// Bounded lexical PDF program editor. Retain state; remove only paint.
    /// Text in selected content and all inline images/unknown operators reject.
    /// Open paths may not cross marked-content boundaries (ambiguous ownership).
    static func removingPaint(_ data: Data, properties: [String: Bool], xObjects: [String: Bool]) throws -> Data {
        let bytes = Array(data); var i = 0
        struct Token { let range: Range<Int>; let text: String; let operand: Bool }
        func space(_ b: UInt8) -> Bool { [0,9,10,12,13,32].contains(b) }
        func delimiter(_ b: UInt8) -> Bool { space(b) || [40,41,60,62,91,93,123,125,47,37].contains(b) }
        func fail(_ detail: String) -> Failure { .unsupported(detail) }
        func skip() {
            while i < bytes.count {
                if space(bytes[i]) { i += 1 }
                else if bytes[i] == 37 { while i < bytes.count && ![10,13].contains(bytes[i]) { i += 1 } }
                else { break }
            }
        }
        func token(depth: Int = 0) throws -> Token {
            guard depth < 64, i < bytes.count else { throw fail("malformed tokens") }
            let start = i, first = bytes[i]
            if first == 40 {
                i += 1; var nesting = 1
                while i < bytes.count && nesting > 0 {
                    if bytes[i] == 92 { i += 1; guard i < bytes.count else { throw fail("truncated string") }; i += 1; continue }
                    if bytes[i] == 40 { nesting += 1 }; if bytes[i] == 41 { nesting -= 1 }; i += 1
                }
                guard nesting == 0 else { throw fail("unclosed string") }
            } else if first == 91 || (first == 60 && i + 1 < bytes.count && bytes[i+1] == 60) {
                let array = first == 91; i += array ? 1 : 2
                while true {
                    skip(); guard i < bytes.count else { throw fail("unclosed composite operand") }
                    if array && bytes[i] == 93 { i += 1; break }
                    if !array && bytes[i] == 62 && i + 1 < bytes.count && bytes[i+1] == 62 { i += 2; break }
                    _ = try token(depth: depth + 1)
                }
            } else if first == 60 {
                i += 1
                while i < bytes.count && bytes[i] != 62 {
                    guard space(bytes[i]) || (48...57).contains(bytes[i]) || (65...70).contains(bytes[i]) || (97...102).contains(bytes[i]) else { throw fail("invalid hex string") }; i += 1
                }
                guard i < bytes.count else { throw fail("unclosed hex string") }; i += 1
            } else {
                guard ![41,62,93,123,125].contains(first) else { throw fail("unexpected delimiter") }
                i += 1; while i < bytes.count && !delimiter(bytes[i]) { i += 1 }
            }
            var text = String(decoding: bytes[start..<i], as: UTF8.self)
            if first == 47 {
                var decoded: [UInt8] = [], cursor = start
                while cursor < i {
                    if bytes[cursor] == 35 {
                        guard cursor + 2 < i, let value = UInt8(String(decoding: bytes[(cursor+1)...(cursor+2)], as: UTF8.self), radix: 16) else { throw fail("invalid name escape") }
                        decoded.append(value); cursor += 3
                    } else { decoded.append(bytes[cursor]); cursor += 1 }
                }
                text = String(decoding: decoded, as: UTF8.self)
            }
            let numeric = text.range(of: "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$", options: .regularExpression) != nil
            return Token(range: start..<i, text: text, operand: [47,40,60,91].contains(first) || numeric || ["true","false","null"].contains(text))
        }
        var operands: [Token] = [], scopes: [Bool] = [], edits: [(Range<Int>, Data)] = []
        var path = false, graphicsDepth = 0, textOpen = false
        let stateCounts = ["q":0,"Q":0,"cm":6,"w":1,"J":1,"j":1,"M":1,"d":2,"ri":1,"i":1,"gs":1,"CS":1,"cs":1,"G":1,"g":1,"RG":3,"rg":3,"K":4,"k":4,"W":0,"W*":0]
        let pathCounts = ["m":2,"l":2,"c":6,"v":4,"y":4,"h":0,"re":4]
        let paints: Set<String> = ["S","s","f","F","f*","B","B*","b","b*"]
        let textOperators: Set<String> = ["BT","ET","Tc","Tw","Tz","TL","Tf","Tr","Ts","Td","TD","Tm","T*","Tj","TJ","'","\""]
        while true {
            skip(); if i == bytes.count { break }
            let next = try token()
            if next.operand { operands.append(next); continue }
            let op = next.text, selected = scopes.last ?? false
            switch op {
            case "BDC", "BMC":
                guard !path, operands.count == (op == "BDC" ? 2 : 1), operands[0].text.hasPrefix("/") else { throw fail("cross-boundary paths or malformed marked content") }
                var own = false
                if operands[0].text == "/OC" {
                    guard op == "BDC", let value = properties[operands[1].text] else { throw fail("unknown or inline optional-content membership") }
                    own = value
                }
                scopes.append(selected || own)
            case "EMC":
                guard operands.isEmpty, !path, !scopes.isEmpty else { throw fail("unbalanced marked content or cross-boundary paths") }; scopes.removeLast()
            case "Do":
                guard operands.count == 1, let target = xObjects[operands[0].text], !path else { throw fail("unknown XObject invocation") }
                if selected || target { edits.append((operands[0].range.lowerBound..<next.range.upperBound, Data())) }
            case "sh":
                guard operands.count == 1, operands[0].text.hasPrefix("/"), !path else { throw fail("malformed shading invocation") }
                if selected { edits.append((operands[0].range.lowerBound..<next.range.upperBound, Data())) }
            case "n":
                guard operands.isEmpty else { throw fail("malformed path terminator") }; path = false
            default:
                if paints.contains(op) {
                    guard operands.isEmpty else { throw fail("malformed painting operator") }
                    if selected { edits.append((next.range, Data("n".utf8))) }; path = false
                } else if let count = pathCounts[op] {
                    guard operands.count == count, operands.allSatisfy({ Double($0.text)?.isFinite == true }) else { throw fail("malformed path geometry") }
                    path = true
                } else if let count = stateCounts[op] {
                    guard operands.count == count else { throw fail("malformed graphics state") }
                    if op == "q" { graphicsDepth += 1 }
                    if op == "Q" { graphicsDepth -= 1; guard graphicsDepth >= 0 else { throw fail("unbalanced graphics state") } }
                } else if ["SC","SCN","sc","scn"].contains(op) {
                    guard !operands.isEmpty else { throw fail("malformed color state") }
                } else if textOperators.contains(op) {
                    guard !selected else { throw fail("text inside selected content") }
                    if op == "BT" { guard !textOpen else { throw fail("nested text objects") }; textOpen = true }
                    if op == "ET" { guard textOpen else { throw fail("unbalanced text objects") }; textOpen = false }
                } else if ["MP","DP"].contains(op) {
                    guard operands.count == (op == "MP" ? 1 : 2), operands[0].text != "/OC" else { throw fail("malformed marked-content point") }
                } else { throw fail("unsupported drawing operator \(op)") }
            }
            operands.removeAll(keepingCapacity: true)
        }
        guard operands.isEmpty, scopes.isEmpty, !path, graphicsDepth == 0, !textOpen else { throw fail("unfinished drawing program") }
        var output = Data(), cursor = 0
        for (range, replacement) in edits { output.append(contentsOf: bytes[cursor..<range.lowerBound]); output.append(replacement); cursor = range.upperBound }
        output.append(contentsOf: bytes[cursor..<bytes.count]); return output
    }
}
