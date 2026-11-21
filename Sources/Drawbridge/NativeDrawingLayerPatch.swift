import Foundation
import CryptoKit

/// Append-only vector-program edits. Shared Form objects and their resources are
/// never mutated: only the selected invocation's ancestors receive new objects.
final class NativeDrawingLayerPatch {
    struct Edit: Sendable {
        let page: Int
        let path: [Int]
        let layers: [Int]
        var fingerprint: String? = nil
    }
    private var objects: [String: Any]
    private var next: Int
    private let source: URL
    private let helper: URL
    private let groups: [String]
    private var streams: [String: Data] = [:]
    private var decodedBytes = 0
    private(set) var originalLayers: [Int] = []
    private(set) var originalFingerprint = ""
    private var expectedFingerprint: String?
    private var found = false
    private var ancestry = Set<String>()

    init(objects: [String: Any], next: Int, source: URL, helper: URL) {
        self.objects = objects; self.next = next; self.source = source; self.helper = helper
        groups = PDFMarkupLayersPatch.foreignReferences(objects)
    }
    static func inspect(source: URL, page: Int, path: [Int], target: Int?, helper: URL? = PDFTKBookmarkWriter.executableURL()) throws -> (layers: [Int], fingerprint: String) {
        guard let helper else { throw NativePDFLayerMutation.Failure.invalid }
        let graph = try PDFLayerPurger.inspect(source, includeStreamData: false, helper: helper)
        guard let tables = graph["qpdf"] as? [[String: Any]], tables.count == 2,
              let entries = graph["pages"] as? [[String: Any]] else { throw NativePDFLayerMutation.Failure.invalid }
        let references = try entries.map { row -> String in
            guard let ref = row["object"] as? String else { throw NativePDFLayerMutation.Failure.invalid }; return ref
        }
        let patch = Self(objects: tables[1], next: (tables[0]["maxobjectid"] as? Int ?? 0) + 1, source: source, helper: helper)
        _ = try patch.apply([.init(page: page, path: path, layers: target.map { [$0] } ?? [])], pages: references)
        return (Array(patch.originalLayers.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }), patch.originalFingerprint)
    }
    private func fail(_ detail: String) -> NativePDFLayerMutation.Failure { .unsupported(detail) }
    private func resolve(_ value: Any?) -> Any? {
        guard let reference = value as? String else { return value }
        return (objects["obj:" + reference] as? [String: Any])?["value"] ?? value
    }
    private func dictionary(_ value: Any?) -> [String: Any] { resolve(value) as? [String: Any] ?? [:] }
    private func add(_ object: [String: Any]) -> String {
        let reference = "\(next) 0 R"; next += 1; objects["obj:" + reference] = object; return reference
    }
    private func data(_ reference: String) throws -> Data {
        if let cached = streams[reference] { return cached }
        if let stream = (objects["obj:" + reference] as? [String: Any])?["stream"] as? [String: Any],
           (stream["dict"] as? [String: Any])?["/Filter"] == nil,
           let encoded = stream["data"] as? String, let bytes = Data(base64Encoded: encoded) { return bytes }
        let parts = reference.split(separator: " ")
        guard parts.count == 3, let number = Int(parts[0]), let generation = Int(parts[1]) else { throw fail("invalid drawing stream reference") }
        let process = Process(), pipe = Pipe()
        process.executableURL = helper
        process.arguments = ["--show-object=\(number),\(generation)", "--filtered-stream-data", source.path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        var bytes = Data()
        while let block = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !block.isEmpty {
            guard bytes.count + block.count <= 64 * 1024 * 1024,
                  decodedBytes + bytes.count + block.count <= 128 * 1024 * 1024 else {
                process.terminate(); process.waitUntilExit(); throw fail("drawing stream exceeds the editing limit")
            }
            bytes.append(block)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw fail("drawing stream could not be decoded") }
        decodedBytes += bytes.count; streams[reference] = bytes; return bytes
    }
    private func stream(_ bytes: Data, dictionary: [String: Any] = [:]) -> String {
        var dictionary = dictionary
        dictionary["/DrawbridgeDrawingLayerProgram"] = true
        for key in ["/Filter", "/DecodeParms", "/Length"] { dictionary.removeValue(forKey: key) }
        return add(["stream": ["dict": dictionary, "data": bytes.base64EncodedString()]])
    }
    private func references(_ value: Any?) -> [String] {
        if let array = resolve(value) as? [String] { return array }
        return (value as? String).map { [$0] } ?? []
    }
    private func resources(_ page: [String: Any]) throws -> [String: Any] {
        var page = page
        for _ in 0..<64 {
            if let value = page["/Resources"] { return dictionary(value) }
            guard let parent = page["/Parent"] else { return [:] }
            page = dictionary(parent)
        }
        throw fail("cyclic page resources")
    }
    func apply(_ edits: [Edit], pages: [String]) throws -> (objects: [String: Any], next: Int, authorized: [String: [String: Any]]) {
        var authorized: [String: [String: Any]] = [:]
        for edit in edits {
            guard pages.indices.contains(edit.page), (1...12).contains(edit.path.count),
                  edit.layers.allSatisfy(groups.indices.contains) else { throw fail("missing drawing path or PDF layer") }
            let reference = pages[edit.page]
            var page = dictionary(reference)
            var program = Data()
            for content in references(page["/Contents"]) { program.append(try data(content)); program.append(10) }
            var resources = try resources(page)
            found = false; expectedFingerprint = edit.fingerprint
            let updated = try rewrite(program, resources: &resources, inherited: [], path: edit.path, targets: edit.layers.map { groups[$0] })
            guard found else { throw fail("the selected drawing path is no longer present") }
            let contents = stream(updated)
            page["/Contents"] = contents; page["/Resources"] = resources
            objects["obj:" + reference] = ["value": page]
            authorized["obj:" + reference] = ["/Contents": contents, "/Resources": resources]
        }
        return (objects, next, authorized)
    }
    private struct Scope { let opening: Data; let group: String? }
    private func rewrite(_ bytes: Data, resources: inout [String: Any], inherited: [String], path: [Int], targets: [String]) throws -> Data {
        guard !path.isEmpty, path.count <= 12 else { throw fail("invalid drawing selection") }
        let tokens = try NativeDrawingProgramTokens.read(bytes)
        var properties = dictionary(resources["/Properties"])
        func property(_ reference: String) -> String {
            if let existing = properties.first(where: { $0.value as? String == reference })?.key { return existing }
            var name = "/DrawbridgeDrawingLayer\(properties.count)"
            while properties[name] != nil { name += "x" }
            properties[name] = reference; return name
        }
        func opening(_ refs: [String]) -> Data { Data(refs.map { "/OC \(property($0)) BDC\n" }.joined().utf8) }
        var scopes: [Scope] = [], operands: [NativeDrawingProgramTokens.Token] = []
        var pathStart: Int?, event = 0
        var edits: [(Range<Int>, Data)] = []
        let pathOperators: Set<String> = ["m", "l", "c", "v", "y", "re", "h"]
        let paints: Set<String> = ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*"]
        let otherPaints: Set<String> = ["sh", "Tj", "TJ", "'", "\""]
        func activeGroups() throws -> [String] { scopes.compactMap(\.group) }
        func replace(_ range: Range<Int>, body: Data, selected: Bool) throws {
            let refs = selected ? targets : inherited + (try activeGroups())
            var seen = Set<String>()
            let conditions = refs.filter { seen.insert($0).inserted }
            guard !conditions.isEmpty else { return }
            var replacement = opening(conditions); replacement.append(body)
            replacement.append(Data(("\n" + String(repeating: "EMC\n", count: conditions.count)).utf8))
            edits.append((range, replacement))
        }
        for token in tokens {
            if token.operand { operands.append(token); continue }
            let start = operands.first?.range.lowerBound ?? token.range.lowerBound
            let range = start..<token.range.upperBound
            if token.text == "BDC" || token.text == "BMC" {
                guard pathStart == nil else { throw fail("marked content crosses a drawing path") }
                var group: String?
                if operands.first?.text == "/OC" {
                    guard token.text == "BDC", operands.count == 2,
                          let reference = properties[operands[1].text] as? String else { throw fail("unsupported optional-content expression") }
                    group = reference
                }
                // Normalize optional content onto paint operations. Keeping an
                // old OC scope around q/Do can retain its hidden state inside a
                // Form even after a selected path moves to a different layer.
                if group != nil { edits.append((range, Data())) }
                scopes.append(Scope(opening: bytes.subdata(in: range), group: group))
            } else if token.text == "EMC" {
                guard pathStart == nil, let scope = scopes.popLast() else { throw fail("unbalanced marked content") }
                if scope.group != nil { edits.append((range, Data())) }
            } else if pathOperators.contains(token.text) {
                if pathStart == nil { pathStart = start }
            } else if paints.contains(token.text) {
                guard let beginning = pathStart else { throw fail("paint without a path") }
                let full = beginning..<token.range.upperBound
                let selected = event == path[0]
                if selected {
                    guard path.count == 1 else { throw fail("drawing selection no longer matches") }
                    let refs = inherited + (try activeGroups())
                    originalLayers = try refs.map { ref in
                        guard let index = groups.firstIndex(of: ref) else { throw fail("conditional or non-native source layer") }; return index
                    }
                    originalFingerprint = SHA256.hash(data: bytes.subdata(in: full)).map { String(format:"%02x", $0) }.joined()
                    if let expectedFingerprint, expectedFingerprint != originalFingerprint { throw fail("the selected drawing path changed outside Drawbridge") }
                    found = true
                }
                try replace(full, body: bytes.subdata(in: full), selected: selected)
                event += 1; pathStart = nil
            } else if ["q", "Q"].contains(token.text), pathStart != nil { throw fail("graphics-state save inside a drawing path")
            } else if token.text == "n" { pathStart = nil
            } else if token.text == "Do" {
                guard pathStart == nil, operands.count == 1 else { throw fail("an XObject crosses a path") }
                let selected = event == path[0]
                if selected {
                    guard path.count > 1 else { throw fail("select a painted path, not an image") }
                    var xObjects = dictionary(resources["/XObject"])
                    guard let reference = xObjects[operands[0].text] as? String,
                          ancestry.insert(reference).inserted,
                          let raw = (objects["obj:" + reference] as? [String: Any])?["stream"] as? [String: Any],
                          var form = raw["dict"] as? [String: Any], form["/Subtype"] as? String == "/Form" else { throw fail("invalid or cyclic Form selection") }
                    defer { ancestry.remove(reference) }
                    var childResources = form["/Resources"].map(dictionary) ?? resources
                    var conditions = inherited + (try activeGroups())
                    if let group = form["/OC"] as? String { conditions.append(group) }
                    else if form["/OC"] != nil { throw fail("direct Form visibility condition") }
                    let child = try rewrite(data(reference), resources: &childResources, inherited: conditions,
                                            path: Array(path.dropFirst()), targets: targets)
                    form.removeValue(forKey: "/OC"); form["/Resources"] = childResources
                    let cloned = stream(child, dictionary: form)
                    var name = "/DrawbridgeDrawingForm\(next)"; while xObjects[name] != nil { name += "x" }
                    xObjects[name] = cloned; resources["/XObject"] = xObjects
                    // The clone carries former parent conditions only on its
                    // unselected paints. This invocation itself is unconditional.
                    edits.append((range, Data("\(name) Do\n".utf8)))
                } else { try replace(range, body: bytes.subdata(in: range), selected: false) }
                event += 1
            } else if otherPaints.contains(token.text) {
                guard pathStart == nil else { throw fail("interleaved painting within a path") }
                try replace(range, body: bytes.subdata(in: range), selected: false)
            }
            operands.removeAll(keepingCapacity: true)
        }
        guard operands.isEmpty, scopes.isEmpty, pathStart == nil else { throw fail("unfinished drawing program") }
        resources["/Properties"] = properties
        var result = Data(), cursor = 0
        for (range, replacement) in edits {
            guard range.lowerBound >= cursor else { throw fail("overlapping drawing operations") }
            result.append(bytes.subdata(in: cursor..<range.lowerBound)); result.append(replacement); cursor = range.upperBound
        }
        result.append(bytes.subdata(in: cursor..<bytes.count)); return result
    }
}

extension NativeDrawingLayerPatch {
    /// CoreGraphics does not consistently evaluate OC marked content inside Form
    /// XObjects. This derived, disposable rendering copy suppresses hidden paint;
    /// the canonical PDF, text/undo objects and exported native OCGs stay intact.
    static func displayCopy(source: URL, hiddenIndices: [Int], helper: URL? = PDFTKBookmarkWriter.executableURL()) throws -> NativePDFLayerMutation.Output? {
        guard !hiddenIndices.isEmpty else { return nil }
        guard let helper else { throw NativePDFLayerMutation.Failure.invalid }
        let json = try PDFLayerPurger.inspect(source, includeStreamData: false, helper: helper)
        guard var tables = json["qpdf"] as? [[String: Any]], tables.count == 2,
              let pages = json["pages"] as? [[String: Any]] else { throw NativePDFLayerMutation.Failure.invalid }
        let editor = Self(objects: tables[1], next: (tables[0]["maxobjectid"] as? Int ?? 0) + 1, source: source, helper: helper)
        guard hiddenIndices.allSatisfy(editor.groups.indices.contains) else { throw NativePDFLayerMutation.Failure.invalid }
        let hidden = Set(hiddenIndices.map { editor.groups[$0] })
        var forms: [String: String] = [:]
        for row in pages {
            guard let reference = row["object"] as? String else { throw NativePDFLayerMutation.Failure.invalid }
            var page = editor.dictionary(reference), resources = try editor.resources(page), program = Data()
            for ref in editor.references(page["/Contents"]) { program.append(try editor.data(ref)); program.append(10) }
            let originalResources = resources
            let filtered = try editor.suppressHiddenPaint(program, resources: &resources, hidden: hidden, forms: &forms)
            if filtered != program || !NSDictionary(dictionary: originalResources).isEqual(to: resources) {
                page["/Contents"] = editor.stream(filtered); page["/Resources"] = resources
                editor.objects["obj:" + reference] = ["value": page]
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawbridgeVisibleLayers-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        let patch = directory.appendingPathComponent("patch.json"), output = directory.appendingPathComponent("display.pdf")
        tables[0]["maxobjectid"] = editor.next - 1
        let changed = editor.objects.filter { key, value in !NSDictionary(dictionary: ["v": value]).isEqual(to: ["v": tables[1][key] ?? NSNull()]) }
        try PDFJSONPatchEncoder.data(withJSONObject: ["qpdf": [tables[0], changed]], options: [.withoutEscapingSlashes]).write(to: patch)
        func run(_ arguments: [String]) throws {
            let process = Process(); process.executableURL = helper; process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NativePDFLayerMutation.Failure.invalid }
        }
        try run([source.path, "--update-from-json=" + patch.path, "--stream-data=preserve", output.path])
        try run(["--check", output.path])
        complete = true; return NativePDFLayerMutation.Output(url: output, directory: directory)
    }
    private func hiddenGroup(_ reference: String, hidden: Set<String>, depth: Int = 0) throws -> Bool {
        guard depth < 32 else { throw fail("cyclic optional-content condition") }
        if hidden.contains(reference) { return true }
        let object = dictionary(reference)
        if object["/Type"] as? String == "/OCG" { return false }
        guard object["/Type"] as? String == "/OCMD", object["/VE"] == nil else { throw fail("unsupported optional-content condition") }
        let groups = references(object["/OCGs"])
        let visible = try groups.map { try !hiddenGroup($0, hidden: hidden, depth: depth + 1) }
        switch object["/P"] as? String ?? "/AnyOn" {
        case "/AllOn": return !visible.allSatisfy { $0 }
        case "/AnyOn": return !visible.contains(true)
        case "/AllOff": return visible.contains(true)
        case "/AnyOff": return visible.allSatisfy { $0 }
        default: throw fail("unsupported optional-content policy")
        }
    }
    private func suppressHiddenPaint(_ program: Data, resources: inout [String: Any], hidden: Set<String>, forms: inout [String: String]) throws -> Data {
        let tokens = try NativeDrawingProgramTokens.read(program)
        let properties = dictionary(resources["/Properties"])
        var xObjects = dictionary(resources["/XObject"])
        var scopes: [Bool] = [], operands: [NativeDrawingProgramTokens.Token] = []
        var renderMode = 0, modeStack: [Int] = [], edits: [(Range<Int>, Data)] = []
        let pathPaints: Set<String> = ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*"]
        let textPaints: Set<String> = ["Tj", "TJ", "'", "\""]
        for token in tokens {
            if token.operand { operands.append(token); continue }
            let range = (operands.first?.range.lowerBound ?? token.range.lowerBound)..<token.range.upperBound
            let suppressed = scopes.contains(true)
            if token.text == "BDC" || token.text == "BMC" {
                var own = false
                if operands.first?.text == "/OC" {
                    guard operands.count == 2, let reference = properties[operands[1].text] as? String else { throw fail("inline optional-content condition") }
                    own = try hiddenGroup(reference, hidden: hidden)
                }
                scopes.append(own)
            } else if token.text == "EMC" {
                guard scopes.popLast() != nil else { throw fail("unbalanced optional-content scopes") }
            } else if token.text == "q" { modeStack.append(renderMode)
            } else if token.text == "Q" {
                guard let previous = modeStack.popLast() else { throw fail("unbalanced drawing state") }; renderMode = previous
            } else if token.text == "Tr" {
                guard operands.count == 1, let value = Int(operands[0].text), (0...7).contains(value) else { throw fail("invalid text rendering mode") }
                renderMode = value
            } else if suppressed && pathPaints.contains(token.text) { edits.append((token.range, Data("n".utf8)))
            } else if suppressed && token.text == "sh" { edits.append((range, Data()))
            } else if suppressed && textPaints.contains(token.text) {
                // Invisible text still advances and clips exactly as before. The
                // editable canonical page supplies selection/search text, unchanged.
                var replacement = Data("\(renderMode >= 4 ? 7 : 3) Tr\n".utf8)
                replacement.append(program.subdata(in: range)); replacement.append(Data("\n\(renderMode) Tr\n".utf8))
                edits.append((range, replacement))
            } else if token.text == "Do" {
                guard operands.count == 1, let reference = xObjects[operands[0].text] as? String,
                      let streamObject = (objects["obj:" + reference] as? [String: Any])?["stream"] as? [String: Any],
                      var definition = streamObject["dict"] as? [String: Any] else { throw fail("invalid drawing resource") }
                let own = try (definition["/OC"] as? String).map { try hiddenGroup($0, hidden: hidden) } ?? false
                if suppressed || own { edits.append((range, Data()))
                } else if definition["/Subtype"] as? String == "/Form" {
                    let originalResources = definition["/Resources"].map(dictionary) ?? resources
                    let signature = reference + ":" + SHA256.hash(data: try JSONSerialization.data(withJSONObject: originalResources, options: [.sortedKeys])).map { String(format:"%02x",$0) }.joined()
                    let replacementReference: String
                    if let cached = forms[signature] { replacementReference = cached }
                    else {
                        guard ancestry.count < 12, ancestry.insert(reference).inserted else { throw fail("cyclic drawing Form") }
                        var childResources = originalResources
                        let bytes = try data(reference)
                        let filtered = try suppressHiddenPaint(bytes, resources: &childResources, hidden: hidden, forms: &forms)
                        ancestry.remove(reference)
                        if filtered == bytes && NSDictionary(dictionary: originalResources).isEqual(to: childResources) { replacementReference = reference }
                        else { definition["/Resources"] = childResources; replacementReference = self.stream(filtered, dictionary: definition) }
                        forms[signature] = replacementReference
                    }
                    if replacementReference != reference {
                        var name = "/DrawbridgeVisibleForm\(next)"; while xObjects[name] != nil { name += "x" }
                        xObjects[name] = replacementReference; edits.append((range, Data("\(name) Do".utf8)))
                    }
                }
            }
            operands.removeAll(keepingCapacity: true)
        }
        guard scopes.isEmpty, modeStack.isEmpty else { throw fail("unbalanced drawing program") }
        resources["/XObject"] = xObjects
        var output = Data(), cursor = 0
        for (range, replacement) in edits {
            output.append(program.subdata(in: cursor..<range.lowerBound)); output.append(replacement); cursor = range.upperBound
        }
        output.append(program.subdata(in: cursor..<program.count)); return output
    }
}
