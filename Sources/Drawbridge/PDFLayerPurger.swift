import Foundation
import Darwin

/// Saved-copy structural transformation. Never renders page content or mutates the input.
enum PDFLayerPurger {
    static func inspect(_ url: URL) throws -> [String: Any] {
        guard let helper = PDFTKBookmarkWriter.executableURL() else { throw CocoaError(.featureUnsupported) }
        let json = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: json) }
        guard PDFTKBookmarkWriter.run(helper, arguments: ["--json=2", "--json-stream-data=inline", "--decode-level=generalized", url.path, json.path]),
              let result = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
    static func purge(source: URL, destination: URL, helper: URL? = PDFTKBookmarkWriter.executableURL(), cancelled: @Sendable () -> Bool = { false }) throws {
        func check() throws { if cancelled() { throw CancellationError() } }
        func rejectAlias() throws {
            guard source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath() else { throw CocoaError(.fileWriteInvalidFileName) }
            if let a = try? FileManager.default.attributesOfItem(atPath: source.path), let b = try? FileManager.default.attributesOfItem(atPath: destination.path),
               (a[.systemNumber] as? NSNumber) == (b[.systemNumber] as? NSNumber), (a[.systemFileNumber] as? NSNumber) == (b[.systemFileNumber] as? NSNumber) { throw CocoaError(.fileWriteInvalidFileName) }
        }
        try check(); try rejectAlias()
        guard let helper else { throw CocoaError(.featureUnsupported) }
        let directory = destination.deletingLastPathComponent().appendingPathComponent(".DrawbridgePurge-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.pdf"), patch = directory.appendingPathComponent("patch.json"), candidate = directory.appendingPathComponent("purged.pdf")
        try FileManager.default.copyItem(at: source, to: input)
        let original = try Data(contentsOf: input)
        var json = try inspect(input)
        guard (json["encrypt"] as? [String: Any])?["encrypted"] as? Bool != true,
              var tables = json["qpdf"] as? [[String: Any]], tables.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
        var objects = tables[1]
        var content = Set<String>(), groups = Set<String>()
        func collect(_ value: Any?) {
            if let ref = value as? String {
                if let entry = objects["obj:" + ref] as? [String: Any], entry["stream"] != nil { content.insert("obj:" + ref) }
                else if let entry = objects["obj:" + ref] as? [String: Any], let array = entry["value"] as? [Any] { array.forEach { collect($0) } }
            } else if let array = value as? [Any] { array.forEach { collect($0) } }
        }
        for (key, value) in objects {
            let entry = value as? [String: Any] ?? [:], dictionary = entry["value"] as? [String: Any] ?? [:]
            if dictionary["/Type"] as? String == "/Sig" || dictionary["/FT"] as? String == "/Sig" { throw CocoaError(.featureUnsupported) }
            if ["/OCG", "/OCMD"].contains(dictionary["/Type"] as? String ?? "") { groups.insert(String(key.dropFirst(4))) }
            if dictionary["/Type"] as? String == "/Page" { collect(dictionary["/Contents"]) }
            if let stream = entry["stream"] as? [String: Any], let dict = stream["dict"] as? [String: Any],
               dict["/Subtype"] as? String == "/Form" || dict["/PatternType"] as? Int == 1 { content.insert(key) }
        }
        func clean(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                var result: [String: Any] = [:]
                for (key, item) in dictionary where !["/OC", "/OCProperties", "/DrawbridgeLayerID", "/DrawbridgeLayerCatalog"].contains(key) {
                    if let ref = item as? String, groups.contains(ref) { continue }
                    result[key] = clean(item)
                }
                return result
            }
            if let array = value as? [Any] { return array.filter { !(($0 as? String).map { groups.contains($0) } ?? false) }.map { clean($0) } }
            return value
        }
        for (key, value) in objects {
            try check()
            if groups.contains(String(key.dropFirst(4))) { objects[key] = ["value": NSNull()]; continue }
            var entry = clean(value) as! [String: Any]
            if content.contains(key), var stream = entry["stream"] as? [String: Any] {
                guard let encoded = stream["data"] as? String, let data = Data(base64Encoded: encoded) else { throw CocoaError(.fileReadCorruptFile) }
                let changed = try unconditional(data)
                if changed != data {
                    var dictionary = stream["dict"] as? [String: Any] ?? [:]
                    dictionary.removeValue(forKey: "/Filter"); dictionary.removeValue(forKey: "/DecodeParms"); dictionary.removeValue(forKey: "/Length")
                    stream["dict"] = dictionary; stream["data"] = changed.base64EncodedString(); entry["stream"] = stream
                }
            }
            objects[key] = entry
        }
        tables[1] = objects; json["qpdf"] = tables
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: patch)
        try check()
        guard PDFTKBookmarkWriter.run(helper, arguments: [input.path, "--update-from-json=" + patch.path, candidate.path]),
              PDFTKBookmarkWriter.run(helper, arguments: ["--check", candidate.path]) else { throw CocoaError(.fileWriteUnknown) }
        let verified = try inspect(candidate)
        guard (verified["pages"] as? [Any])?.count == (json["pages"] as? [Any])?.count else { throw CocoaError(.fileReadCorruptFile) }
        // Assert no serialized optional-content graph survives the rewrite.
        func hasOC(_ value: Any) -> Bool {
            if let d = value as? [String: Any] {
                if d["/OC"] != nil || d["/OCProperties"] != nil || ["/OCG", "/OCMD"].contains(d["/Type"] as? String ?? "") { return true }
                return d.values.contains { hasOC($0) }
            }
            return (value as? [Any])?.contains { hasOC($0) } ?? false
        }
        guard !hasOC(verified), try Data(contentsOf: source) == original else { throw CocoaError(.fileWriteUnknown) }
        // Re-discover executable streams in the written file: qpdf may renumber
        // objects. Graph validation alone cannot detect an escaped /OC BDC tag.
        guard let verifiedObjects = (verified["qpdf"] as? [[String: Any]])?.last else { throw CocoaError(.fileReadCorruptFile) }
        objects = verifiedObjects; content.removeAll()
        for (key, value) in objects {
            let entry = value as? [String: Any] ?? [:]
            if let dictionary = entry["value"] as? [String: Any], dictionary["/Type"] as? String == "/Page" { collect(dictionary["/Contents"]) }
            if let stream = entry["stream"] as? [String: Any], let dictionary = stream["dict"] as? [String: Any],
               dictionary["/Subtype"] as? String == "/Form" || dictionary["/PatternType"] as? Int == 1 { content.insert(key) }
        }
        for key in content {
            try check()
            guard let stream = (objects[key] as? [String: Any])?["stream"] as? [String: Any],
                  let encoded = stream["data"] as? String, let data = Data(base64Encoded: encoded),
                  try unconditional(data) == data else { throw CocoaError(.fileReadCorruptFile) }
        }
        try check(); try rejectAlias()
        guard Darwin.renamex_np(candidate.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Lexical PDF scanner: strings, names and composite operands are opaque.
    /// Optional-content BDC is replaced by a neutral BMC; its EMC stays balanced.
    /// Inline-image payloads are opaque; unsupported encodings fail closed.
    static func unconditional(_ data: Data) throws -> Data {
        let bytes = [UInt8](data); var i = 0, operands: [(String, Int)] = [], replacements: [(Range<Int>, [UInt8])] = []
        func whitespace(_ c: UInt8) -> Bool { [0, 9, 10, 12, 13, 32].contains(c) }
        func delimiter(_ c: UInt8) -> Bool { whitespace(c) || [40,41,60,62,91,93,123,125,47,37].contains(c) }
        func token() throws -> (String, Int) {
            let start = i
            if bytes[i] == 40 {
                i += 1; var depth = 1
                while i < bytes.count && depth > 0 {
                    if bytes[i] == 92 { i = min(i + 2, bytes.count); continue }
                    if bytes[i] == 40 { depth += 1 }; if bytes[i] == 41 { depth -= 1 }; i += 1
                }
                guard depth == 0 else { throw CocoaError(.fileReadCorruptFile) }
            } else if bytes[i] == 91 || (bytes[i] == 60 && i + 1 < bytes.count && bytes[i+1] == 60) {
                let array = bytes[i] == 91; i += array ? 1 : 2
                while i < bytes.count {
                    if whitespace(bytes[i]) { i += 1; continue }
                    if bytes[i] == 37 { while i < bytes.count && bytes[i] != 10 && bytes[i] != 13 { i += 1 }; continue }
                    if array && bytes[i] == 93 { i += 1; return (String(decoding:bytes[start..<i],as:UTF8.self),start) }
                    if !array && bytes[i] == 62 && i+1 < bytes.count && bytes[i+1] == 62 { i += 2; return (String(decoding:bytes[start..<i],as:UTF8.self),start) }
                    _ = try token()
                }
                throw CocoaError(.fileReadCorruptFile)
            } else if bytes[i] == 60 {
                i += 1; while i < bytes.count && bytes[i] != 62 { i += 1 }; guard i < bytes.count else { throw CocoaError(.fileReadCorruptFile) }; i += 1
            } else {
                i += 1; while i < bytes.count && !delimiter(bytes[i]) { i += 1 }
            }
            // PDF name escapes are hexadecimal bytes, not case-sensitive text substitutions.
            if bytes[start] == 47 {
                func hex(_ c: UInt8) -> UInt8? {
                    switch c {
                    case 48...57: return c - 48
                    case 65...70: return c - 65 + 10
                    case 97...102: return c - 97 + 10
                    default: return nil
                    }
                }
                var decoded: [UInt8] = [], cursor = start
                while cursor < i {
                    if bytes[cursor] == 35 {
                        guard cursor + 2 < i, let high = hex(bytes[cursor + 1]), let low = hex(bytes[cursor + 2]) else { throw CocoaError(.fileReadCorruptFile) }
                        decoded.append(high * 16 + low); cursor += 3
                    } else { decoded.append(bytes[cursor]); cursor += 1 }
                }
                return (String(decoding: decoded, as: UTF8.self), start)
            }
            return (String(decoding:bytes[start..<i],as:UTF8.self),start)
        }
        while i < bytes.count {
            if whitespace(bytes[i]) { i += 1; continue }
            if bytes[i] == 37 { while i < bytes.count && bytes[i] != 10 && bytes[i] != 13 { i += 1 }; continue }
            let (text,start) = try token()
            let first = text.utf8.first ?? 0
            if first == 47 || first == 40 || first == 60 || first == 91 || Double(text) != nil || ["true","false","null"].contains(text) { operands.append((text,start)); continue }
            if text == "BI" {
                guard operands.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                func skipSpace() {
                    while i < bytes.count {
                        if whitespace(bytes[i]) { i += 1 }
                        else if bytes[i] == 37 { while i < bytes.count && bytes[i] != 10 && bytes[i] != 13 { i += 1 } }
                        else { break }
                    }
                }
                var dictionary: [String:String] = [:]
                while true {
                    skipSpace(); guard i < bytes.count else { throw CocoaError(.fileReadCorruptFile) }
                    let key = try token().0
                    if key == "ID" { break }
                    guard key.hasPrefix("/") else { throw CocoaError(.fileReadCorruptFile) }
                    skipSpace(); guard i < bytes.count else { throw CocoaError(.fileReadCorruptFile) }
                    dictionary[key] = try token().0
                }
                guard i < bytes.count, whitespace(bytes[i]) else { throw CocoaError(.fileReadCorruptFile) }
                let separator = bytes[i]; i += 1
                if separator == 13 && i < bytes.count && bytes[i] == 10 { i += 1 }
                let filter = dictionary["/F"] ?? dictionary["/Filter"]
                if let filter {
                    // Only the first (outermost) filter determines the encoded boundary.
                    let outer = filter.trimmingCharacters(in: CharacterSet(charactersIn: "[] \r\n\t")).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                    if ["/AHx", "/ASCIIHexDecode"].contains(outer) {
                        while i < bytes.count && bytes[i] != 62 {
                            guard whitespace(bytes[i]) || (48...57).contains(bytes[i]) || (65...70).contains(bytes[i]) || (97...102).contains(bytes[i]) else { throw CocoaError(.fileReadCorruptFile) }
                            i += 1
                        }
                        guard i < bytes.count else { throw CocoaError(.fileReadCorruptFile) }; i += 1
                    } else if ["/A85", "/ASCII85Decode"].contains(outer) {
                        while i + 1 < bytes.count && !(bytes[i] == 126 && bytes[i+1] == 62) { i += 1 }
                        guard i + 1 < bytes.count else { throw CocoaError(.fileReadCorruptFile) }; i += 2
                    } else { throw CocoaError(.featureUnsupported) }
                } else {
                    guard let width = Int(dictionary["/W"] ?? dictionary["/Width"] ?? ""), width > 0,
                          let height = Int(dictionary["/H"] ?? dictionary["/Height"] ?? ""), height > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    let mask = (dictionary["/IM"] ?? dictionary["/ImageMask"]) == "true"
                    let bits = mask ? 1 : Int(dictionary["/BPC"] ?? dictionary["/BitsPerComponent"] ?? "") ?? 0
                    let color = dictionary["/CS"] ?? dictionary["/ColorSpace"] ?? ""
                    let components = mask || ["/G", "/DeviceGray"].contains(color) ? 1 : ["/RGB", "/DeviceRGB"].contains(color) ? 3 : ["/CMYK", "/DeviceCMYK"].contains(color) ? 4 : 0
                    guard [1,2,4,8,16].contains(bits), components > 0,
                          width <= (Int.max - 7) / components / bits else { throw CocoaError(.featureUnsupported) }
                    let row = (width * components * bits + 7) / 8
                    guard height <= (bytes.count - i) / row else { throw CocoaError(.fileReadCorruptFile) }
                    i += row * height
                }
                guard i < bytes.count, whitespace(bytes[i]) else { throw CocoaError(.fileReadCorruptFile) }
                skipSpace()
                guard i < bytes.count, try token().0 == "EI" else { throw CocoaError(.fileReadCorruptFile) }
                continue
            }
            if text == "BDC", operands.count == 2, operands[0].0 == "/OC" {
                replacements.append((operands[0].1..<i, Array("/Artifact BMC".utf8)))
            }
            operands.removeAll(keepingCapacity:true)
        }
        // /Contents arrays are ordered programs. Do not silently discard operands
        // that could be completed by an operator in the next stream. Supporting
        // such programs requires concatenation; until then reject before publication.
        guard operands.isEmpty else { throw CocoaError(.featureUnsupported) }
        var result = bytes
        for (range,replacement) in replacements.reversed() { result.replaceSubrange(range,with:replacement) }
        return Data(result)
    }
}
