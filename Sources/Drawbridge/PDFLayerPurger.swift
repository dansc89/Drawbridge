import Foundation
import Darwin
import zlib

/// Saved-copy structural transformation. Never renders page content or mutates the input.
enum PDFLayerPurger {
    struct Progress: Sendable {
        let detail: String
        var completed: Int? = nil
        var total: Int? = nil
    }
    /// Cancellation is scoped to this invocation's child, never other qpdf clients.
    /// Polling avoids a termination-handler/run-loop dependency on the calling queue.
    private static func run(_ executable: URL, arguments: [String], cancelled: () -> Bool) throws -> Bool {
        if cancelled() { throw CancellationError() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Check again immediately before launch, including cancellation during setup.
        if cancelled() { throw CancellationError() }
        do { try process.run() }
        catch {
            if cancelled() { throw CancellationError() }
            return false
        }
        var wasCancelled = cancelled()
        while process.isRunning {
            if wasCancelled || cancelled() {
                wasCancelled = true
                process.terminate()
                let deadline = ProcessInfo.processInfo.systemUptime + 0.2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // Always reap our child before throwing or releasing staging files.
        process.waitUntilExit()
        if wasCancelled || cancelled() { throw CancellationError() }
        return process.terminationStatus == 0 || process.terminationStatus == 3
    }

    static func inspect(_ url: URL, includeStreamData: Bool = true, helper: URL? = PDFTKBookmarkWriter.executableURL(), cancelled: () -> Bool = { false }) throws -> [String: Any] {
        guard let helper else { throw CocoaError(.featureUnsupported) }
        let json = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: json) }
        guard try run(helper, arguments: ["--json=2", "--json-stream-data=\(includeStreamData ? "inline" : "none")", "--decode-level=\(includeStreamData ? "generalized" : "none")", url.path, json.path], cancelled: cancelled),
              let result = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
    static func purge(source: URL, destination: URL, helper: URL? = PDFTKBookmarkWriter.executableURL(), cancelled: @Sendable () -> Bool = { false }, progress: @Sendable (Progress) -> Void = { _ in }) throws {
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
        let original = try Data(contentsOf: input, options: .mappedIfSafe)
        progress(Progress(detail: "Reading page and layer information…"))
        var json = try inspect(input, includeStreamData: false, helper: helper, cancelled: cancelled)
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
        // Request payloads only for executable streams. Embedded image/font data
        // stays in the source PDF instead of passing through base64 JSON twice.
        func drawingStreams(_ url: URL, keys: Set<String>, phase: String, consume: (String, Data, Int) throws -> Void) throws {
            let sorted = keys.sorted()
            for start in stride(from: 0, to: sorted.count, by: 1024) {
                try autoreleasepool {
                try check()
                let batch = Array(sorted[start..<min(start + 1024, sorted.count)])
                let jsonURL = directory.appendingPathComponent("drawing-streams.json")
                var args = ["--json=2", "--json-key=qpdf", "--json-stream-data=inline", "--decode-level=generalized"]
                for key in batch {
                    let parts = key.dropFirst(4).split(separator: " ")
                    guard parts.count == 3, Int(parts[0]) != nil, Int(parts[1]) != nil, parts[2] == "R" else { throw CocoaError(.fileReadCorruptFile) }
                    args.append("--json-object=\(parts[0]),\(parts[1])")
                }
                args += [url.path, jsonURL.path]
                guard try run(helper, arguments: args, cancelled: cancelled),
                      let selected = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any],
                      let selectedObjects = (selected["qpdf"] as? [[String: Any]])?.last else { throw CocoaError(.fileReadCorruptFile) }
                for (offset, key) in batch.enumerated() {
                    try check()
                    guard let stream = (selectedObjects[key] as? [String: Any])?["stream"] as? [String: Any],
                          let encoded = stream["data"] as? String, let data = Data(base64Encoded: encoded) else { throw CocoaError(.fileReadCorruptFile) }
                    // One decoded original at a time. Only changed base64 payloads
                    // survive this callback in the metadata patch.
                    try consume(key, data, start + offset + 1)
                }
                let done = min(start + batch.count, sorted.count)
                progress(Progress(detail: "\(phase): \(done) of \(sorted.count) drawing sections", completed: done, total: sorted.count))
                }
            }
        }
        let layerTotal = groups.count
        progress(Progress(detail: "Found \(layerTotal) layer controls across \((json["pages"] as? [Any])?.count ?? 0) pages"))
        var layersPrepared = 0
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
        let objectKeys = objects.keys.sorted()
        for (index, key) in objectKeys.enumerated() {
            try check()
            let value = objects[key]!
            if groups.contains(String(key.dropFirst(4))) { objects[key] = ["value": NSNull()]; layersPrepared += 1 }
            else {
            objects[key] = clean(value)
            }
            if index % 128 == 0 || index + 1 == objectKeys.count {
                progress(Progress(detail: "Preparing layer controls: \(layersPrepared)/\(layerTotal)", completed: index + 1, total: objectKeys.count))
            }
        }
        try drawingStreams(input, keys: content, phase: "Preparing drawings") { key, data, done in
            guard var entry = objects[key] as? [String: Any], var stream = entry["stream"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            let changed = try unconditional(data, cancelled: cancelled)
            if changed != data {
                var dictionary = stream["dict"] as? [String: Any] ?? [:]
                dictionary.removeValue(forKey: "/Filter"); dictionary.removeValue(forKey: "/DecodeParms"); dictionary.removeValue(forKey: "/Length")
                stream["dict"] = dictionary; stream["data"] = changed.base64EncodedString(); entry["stream"] = stream
                objects[key] = entry
            }
            if done % 128 == 0 || done == content.count {
                progress(Progress(detail: "Layer controls: \(layersPrepared)/\(layerTotal) · Drawings: \(done)/\(content.count)", completed: done, total: content.count))
            }
        }
        tables[1] = objects; json["qpdf"] = tables
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: patch)
        try check()
        progress(Progress(detail: "Writing the working copy; verifying before saving…"))
        guard try run(helper, arguments: [input.path, "--update-from-json=" + patch.path, candidate.path], cancelled: cancelled),
              try run(helper, arguments: ["--check", candidate.path], cancelled: cancelled) else { throw CocoaError(.fileWriteUnknown) }
        progress(Progress(detail: "Verifying page count and removed layer controls…"))
        let verified = try inspect(candidate, includeStreamData: false, helper: helper, cancelled: cancelled)
        guard (verified["pages"] as? [Any])?.count == (json["pages"] as? [Any])?.count else { throw CocoaError(.fileReadCorruptFile) }
        // Assert no serialized optional-content graph survives the rewrite.
        func hasOC(_ value: Any) -> Bool {
            if let d = value as? [String: Any] {
                if d["/OC"] != nil || d["/OCProperties"] != nil || ["/OCG", "/OCMD"].contains(d["/Type"] as? String ?? "") { return true }
                return d.values.contains { hasOC($0) }
            }
            return (value as? [Any])?.contains { hasOC($0) } ?? false
        }
        guard !hasOC(verified), try Data(contentsOf: source, options: .mappedIfSafe) == original else { throw CocoaError(.fileWriteUnknown) }
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
        try drawingStreams(candidate, keys: content, phase: "Verifying drawings") { _, data, done in
            try check()
            try validateUnconditional(data, cancelled: cancelled)
            if done % 128 == 0 || done == content.count {
                progress(Progress(detail: "Verified \(done) of \(content.count) drawing sections; no layer controls remain", completed: done, total: content.count))
            }
        }
        progress(Progress(detail: "Verification complete; saving the purged PDF…"))
        try check(); try rejectAlias()
        guard Darwin.renamex_np(candidate.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Find the zlib endpoint without retaining decoded pixels or changing encoded
    /// bytes. Neither EI-looking bytes nor predictor parameters delimit this stream.
    private static func flateEncodedLength(_ bytes: UnsafeBufferPointer<UInt8>, startingAt offset: Int, cancelled: () -> Bool) throws -> Int {
        guard offset < bytes.count, bytes.count - offset <= Int(UInt32.max) else { throw CocoaError(.fileReadCorruptFile) }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { inflateEnd(&stream) }
        var scratch = [UInt8](repeating: 0, count: 32768)
        stream.next_in = UnsafeMutablePointer(mutating: bytes.baseAddress! + offset)
        stream.avail_in = UInt32(bytes.count - offset)
        return try scratch.withUnsafeMutableBufferPointer { output in
            while true {
                if cancelled() { throw CancellationError() }
                stream.next_out = output.baseAddress!
                stream.avail_out = UInt32(output.count)
                let before = stream.total_in
                let status = inflate(&stream, Z_NO_FLUSH)
                // Bound work on corrupt or malicious compressed image data.
                guard stream.total_out <= 512 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
                if status == Z_STREAM_END { return Int(stream.total_in) }
                guard status == Z_OK, stream.total_in > before || stream.avail_out == 0 else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
    }

    /// Lexical PDF scanner: strings, names and composite operands are opaque.
    /// Optional-content BDC is replaced by a neutral BMC; its EMC stays balanced.
    /// Inline-image payloads are opaque; unsupported encodings fail closed.
    static func unconditional(_ data: Data, removingXObjects: Set<String>? = nil, cancelled: () -> Bool = { false }) throws -> Data {
        try scan(data, removingXObjects: removingXObjects, validationOnly: false, cancelled: cancelled)
    }

    /// Validation shares the complete lexer, but never constructs rewritten bytes.
    static func validateUnconditional(_ data: Data, cancelled: () -> Bool = { false }) throws {
        _ = try scan(data, removingXObjects: nil, validationOnly: true, cancelled: cancelled)
    }

    private static func scan(_ data: Data, removingXObjects: Set<String>?, validationOnly: Bool, cancelled: () -> Bool) throws -> Data {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
        let bytes = raw.bindMemory(to: UInt8.self)
        var removed: [String:Int] = [:]
        var i = 0, operands: [(Range<Int>, Int)] = [], replacements: [(Range<Int>, [UInt8])] = []
        var nextCheckpoint = 0
        func checkpoint() throws {
            if i >= nextCheckpoint {
                if cancelled() { throw CancellationError() }
                nextCheckpoint = i + 4096
            }
        }
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 65 + 10
            case 97...102: return c - 97 + 10
            default: return nil
            }
        }
        // Operators compare byte ranges directly. Only inline-image dictionary
        // values and explicitly targeted XObject names need materialized text.
        func matches(_ range: Range<Int>, _ expected: StaticString) -> Bool {
            expected.withUTF8Buffer { target in
                var cursor = range.lowerBound, index = 0
                while cursor < range.upperBound {
                    var byte = bytes[cursor]; cursor += 1
                    if bytes[range.lowerBound] == 47 && byte == 35 {
                        guard cursor + 1 < range.upperBound, let high = hex(bytes[cursor]), let low = hex(bytes[cursor + 1]) else { return false }
                        byte = high * 16 + low; cursor += 2
                    }
                    guard index < target.count, target[index] == byte else { return false }
                    index += 1
                }
                return index == target.count
            }
        }
        func text(_ range: Range<Int>) -> String {
            guard bytes[range.lowerBound] == 47, bytes[range].contains(35) else { return String(decoding: bytes[range], as: UTF8.self) }
            var decoded: [UInt8] = [], cursor = range.lowerBound
            while cursor < range.upperBound {
                if bytes[cursor] == 35, let high = hex(bytes[cursor + 1]), let low = hex(bytes[cursor + 2]) {
                    decoded.append(high * 16 + low); cursor += 3
                } else { decoded.append(bytes[cursor]); cursor += 1 }
            }
            return String(decoding: decoded, as: UTF8.self)
        }
        func number(_ range: Range<Int>) -> Bool {
            var digit = false, dot = false
            for cursor in range {
                let c = bytes[cursor]
                if (48...57).contains(c) { digit = true }
                else if c == 46 && !dot { dot = true }
                else if (c == 43 || c == 45) && cursor == range.lowerBound { continue }
                else { return false }
            }
            return digit
        }
        func whitespace(_ c: UInt8) -> Bool { [0, 9, 10, 12, 13, 32].contains(c) }
        func delimiter(_ c: UInt8) -> Bool { whitespace(c) || [40,41,60,62,91,93,123,125,47,37].contains(c) }
        func skipSpace() throws {
            while i < bytes.count {
                try checkpoint()
                if whitespace(bytes[i]) { i += 1 }
                else if bytes[i] == 37 {
                    while i < bytes.count && bytes[i] != 10 && bytes[i] != 13 { try checkpoint(); i += 1 }
                } else { break }
            }
        }
        func token() throws -> (Range<Int>, Int) {
            let start = i
            if bytes[i] == 40 {
                i += 1; var depth = 1
                while i < bytes.count && depth > 0 {
                    try checkpoint()
                    if bytes[i] == 92 { i = min(i + 2, bytes.count); continue }
                    if bytes[i] == 40 { depth += 1 }; if bytes[i] == 41 { depth -= 1 }; i += 1
                }
                guard depth == 0 else { throw CocoaError(.fileReadCorruptFile) }
            } else if bytes[i] == 91 || (bytes[i] == 60 && i + 1 < bytes.count && bytes[i+1] == 60) {
                let array = bytes[i] == 91; i += array ? 1 : 2
                while i < bytes.count {
                    try skipSpace()
                    guard i < bytes.count else { break }
                    if array && bytes[i] == 93 { i += 1; return (start..<i,start) }
                    if !array && bytes[i] == 62 && i+1 < bytes.count && bytes[i+1] == 62 { i += 2; return (start..<i,start) }
                    _ = try token()
                }
                throw CocoaError(.fileReadCorruptFile)
            } else if bytes[i] == 60 {
                i += 1
                while i < bytes.count && bytes[i] != 62 { try checkpoint(); i += 1 }
                guard i < bytes.count else { throw CocoaError(.fileReadCorruptFile) }; i += 1
            } else {
                i += 1
                while i < bytes.count && !delimiter(bytes[i]) { try checkpoint(); i += 1 }
            }
            // Validate every name escape, including names inside composite operands.
            // No decoded name buffer is needed merely to compare /OC.
            if bytes[start] == 47 {
                var cursor = start
                while cursor < i {
                    if bytes[cursor] == 35 {
                        guard cursor + 2 < i, hex(bytes[cursor + 1]) != nil, hex(bytes[cursor + 2]) != nil else { throw CocoaError(.fileReadCorruptFile) }
                        cursor += 3
                    } else { cursor += 1 }
                }
            }
            return (start..<i,start)
        }
        while i < bytes.count {
            try skipSpace()
            guard i < bytes.count else { break }
            let (range,start) = try token()
            let first = bytes[start]
            if first == 47 || first == 40 || first == 60 || first == 91 || number(range) || matches(range, "true") || matches(range, "false") || matches(range, "null") { operands.append((range,start)); continue }
            if matches(range, "BI") {
                guard operands.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                var dictionary: [String:String] = [:]
                while true {
                    try skipSpace(); guard i < bytes.count else { throw CocoaError(.fileReadCorruptFile) }
                    let key = text(try token().0)
                    if key == "ID" { break }
                    guard key.hasPrefix("/") else { throw CocoaError(.fileReadCorruptFile) }
                    try skipSpace(); guard i < bytes.count else { throw CocoaError(.fileReadCorruptFile) }
                    dictionary[key] = text(try token().0)
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
                            try checkpoint()
                            guard whitespace(bytes[i]) || (48...57).contains(bytes[i]) || (65...70).contains(bytes[i]) || (97...102).contains(bytes[i]) else { throw CocoaError(.fileReadCorruptFile) }
                            i += 1
                        }
                        guard i < bytes.count else { throw CocoaError(.fileReadCorruptFile) }; i += 1
                    } else if ["/A85", "/ASCII85Decode"].contains(outer) {
                        while i + 1 < bytes.count && !(bytes[i] == 126 && bytes[i+1] == 62) { try checkpoint(); i += 1 }
                        guard i + 1 < bytes.count else { throw CocoaError(.fileReadCorruptFile) }; i += 2
                    } else if ["/Fl", "/FlateDecode"].contains(outer) {
                        i += try flateEncodedLength(bytes, startingAt: i, cancelled: cancelled)
                    } else {
                        throw NSError(domain: "DrawbridgePurge", code: 4, userInfo: [NSLocalizedDescriptionKey: "An inline image uses an unsupported encoding (\(outer)). No changes were saved."])
                    }
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
                try skipSpace()
                guard i < bytes.count, matches(try token().0, "EI") else { throw CocoaError(.fileReadCorruptFile) }
                continue
            }
            if removingXObjects == nil, matches(range, "BDC"), let tag = operands.first, matches(tag.0, "/OC") {
                guard operands.count == 2, !validationOnly else { throw CocoaError(.fileReadCorruptFile) }
                replacements.append((operands[0].1..<i, Array("/Artifact BMC".utf8)))
            }
            if matches(range, "Do"), operands.count == 1, let names = removingXObjects, names.contains(text(operands[0].0)) {
                removed[text(operands[0].0), default:0] += 1
                replacements.append((operands[0].1..<i, []))
            }
            operands.removeAll(keepingCapacity:true)
        }
        // /Contents arrays are ordered programs. Do not silently discard operands
        // that could be completed by an operator in the next stream. Supporting
        // such programs requires concatenation; until then reject before publication.
        guard operands.isEmpty else { throw CocoaError(.featureUnsupported) }
        if let names = removingXObjects {
            guard Set(removed.keys) == names, removed.values.allSatisfy({ $0 == 1 }) else { throw CocoaError(.featureUnsupported) }
        }
        // Build once in source order; repeated middle-of-buffer replacement is
        // quadratic on drawing sections with thousands of optional-content tags.
        guard !replacements.isEmpty else { return data }
        var result = Data();result.reserveCapacity(bytes.count)
        var cursor = 0
        for (range,replacement) in replacements {
            result.append(contentsOf: bytes[cursor..<range.lowerBound])
            result.append(contentsOf: replacement);cursor = range.upperBound
        }
        result.append(contentsOf: bytes[cursor..<bytes.count])
        return result
        }
    }
}
