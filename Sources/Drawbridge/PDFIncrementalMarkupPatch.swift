import Foundation
import CoreFoundation
import Darwin

/// Append an incremental PDF revision. Existing stream objects cannot be replaced.
enum PDFIncrementalMarkupPatch {
    @discardableResult
    static func append(original: Data, baseline: [String: Any], updated: [String: Any], snapshot: URL? = nil, to url: URL) throws -> [String] {
        guard let before = (baseline["qpdf"] as? [[String: Any]])?.last,
              let tables = updated["qpdf"] as? [[String: Any]], let after = tables.last,
              let maximum = tables.first?["maxobjectid"] as? Int,
              var trailer = (before["trailer"] as? [String: Any])?["value"] as? [String: Any],
              trailer["/Encrypt"] == nil else { throw CocoaError(.fileWriteUnknown) }
        let suffix = String(decoding: original.suffix(65536), as: UTF8.self)
        guard let marker = suffix.range(of: "startxref", options: .backwards),
              let previous = Int(suffix[marker.upperBound...].split(whereSeparator: { $0.isWhitespace }).first ?? ""),
              previous >= 0, previous < original.count else { throw CocoaError(.fileReadCorruptFile) }
        var appended = Data("\n".utf8)
        var entries: [(number: Int, generation: Int, offset: Int)] = []
        var changed = [String]()
        for key in after.keys.sorted() where key.hasPrefix("obj:") {
            guard let object = after[key] as? [String: Any] else { throw CocoaError(.fileWriteUnknown) }
            if let old = before[key] as? NSDictionary, old.isEqual(object as NSDictionary) { continue }
            let components = key.dropFirst(4).split(separator: " ")
            guard components.count == 3, components[2] == "R", let number = Int(components[0]),
                  let generation = Int(components[1]), number > 0, generation >= 0, generation < 65536 else { throw CocoaError(.fileWriteUnknown) }
            // Original raster, font and page content stream objects are immutable.
            guard (before[key] as? [String: Any])?["stream"] == nil else { throw CocoaError(.fileWriteUnknown) }
            changed.append(key)
            entries.append((number, generation, original.count + appended.count))
            appended.append(Data("\(number) \(generation) obj\n".utf8))
            if let value = object["value"] {
                appended.append(Data(try encode(value).utf8))
            } else if let stream = object["stream"] as? [String: Any], var dictionary = stream["dict"] as? [String: Any],
                      dictionary["/DrawbridgeRectangleAppearance"] as? Bool == true,
                      let encoded = stream["data"] as? String, let bytes = Data(base64Encoded: encoded) {
                dictionary["/Length"] = bytes.count
                appended.append(Data(try encode(dictionary).utf8)); appended.append(Data("\nstream\n".utf8))
                appended.append(bytes); appended.append(Data("\nendstream".utf8))
            } else { throw CocoaError(.fileWriteUnknown) }
            appended.append(Data("\nendobj\n".utf8))
        }
        let offset = original.count + appended.count
        let usesStream = trailer["/Type"] as? String == "/XRef"
        for key in ["/Type", "/W", "/Index", "/Length", "/Filter", "/DecodeParms", "/XRefStm"] { trailer.removeValue(forKey: key) }
        trailer["/Prev"] = previous
        if usesStream {
            let xrefNumber = maximum + 1
            entries.append((xrefNumber, 0, offset))
            let sorted = entries.sorted { $0.number < $1.number }
            var bytes = Data(), indices = [Int]()
            for entry in sorted {
                indices += [entry.number, 1]
                bytes.append(1)
                for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((UInt64(entry.offset) >> shift) & 255)) }
                bytes.append(UInt8(entry.generation >> 8)); bytes.append(UInt8(entry.generation & 255))
            }
            trailer["/Type"] = "/XRef"; trailer["/W"] = [1, 8, 2]; trailer["/Index"] = indices
            trailer["/Size"] = xrefNumber + 1; trailer["/Length"] = bytes.count
            appended.append(Data("\(xrefNumber) 0 obj\n".utf8))
            appended.append(Data(try encode(trailer).utf8)); appended.append(Data("\nstream\n".utf8))
            appended.append(bytes); appended.append(Data("\nendstream\nendobj\n".utf8))
        } else {
            var xref = "xref\n0 1\n0000000000 65535 f \n"
            for entry in entries.sorted(by: { $0.number < $1.number }) {
                guard entry.offset < 10_000_000_000 else { throw CocoaError(.fileWriteUnknown) }
                xref += "\(entry.number) 1\n" + String(format: "%010lld %05d n \n", Int64(entry.offset), entry.generation)
            }
            trailer["/Size"] = maximum + 1
            xref += "trailer\n" + (try encode(trailer)) + "\n"
            appended.append(Data(xref.utf8))
        }
        appended.append(Data("startxref\n\(offset)\n%%EOF\n".utf8))
        // APFS clones preserve the staged original without copying large image
        // payloads. Other volumes retain the safe byte-copy fallback.
        if let snapshot, clonefile(snapshot.path, url.path, 0) == 0 { }
        else { try original.write(to: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        guard try handle.seekToEnd() == UInt64(original.count) else { throw CocoaError(.fileWriteUnknown) }
        try handle.write(contentsOf: appended)
        return changed
    }

    static func encode(_ value: Any) throws -> String {
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return String(decoding: try PDFJSONPatchEncoder.data(withJSONObject: number, options: .fragmentsAllowed), as: UTF8.self)
        }
        if let text = value as? String {
            if text.hasPrefix("u:") {
                var bytes = Data([0xfe, 0xff])
                for unit in text.dropFirst(2).utf16 { bytes.append(UInt8(unit >> 8)); bytes.append(UInt8(unit & 255)) }
                return "<" + bytes.map { String(format: "%02x", $0) }.joined() + ">"
            }
            if text.hasPrefix("b:") {
                let hex = text.dropFirst(2)
                guard hex.count % 2 == 0, hex.allSatisfy({ $0.isHexDigit }) else { throw CocoaError(.fileWriteUnknown) }
                return "<\(hex)>"
            }
            if text.hasPrefix("n:/") { return String(text.dropFirst(2)) }
            if text.hasPrefix("/") {
                let safe = Set("!\"$&'*+,-.0123456789:;=?@ABCDEFGHIJKLMNOPQRSTUVWXYZ\\^_`abcdefghijklmnopqrstuvwxyz|~".utf8)
                return "/" + text.dropFirst().utf8.map { safe.contains($0) ? String(UnicodeScalar($0)) : String(format: "#%02x", $0) }.joined()
            }
            let parts = text.split(separator: " ")
            if parts.count == 3, parts[2] == "R", let object = Int(parts[0]), object > 0,
               let generation = Int(parts[1]), generation >= 0 { return text }
            throw CocoaError(.fileWriteUnknown)
        }
        if let array = value as? [Any] { return "[" + (try array.map(encode)).joined(separator: " ") + "]" }
        if let dictionary = value as? [String: Any] {
            return "<<" + (try dictionary.keys.sorted().map { try encode($0) + " " + encode(dictionary[$0]!) }).joined(separator: " ") + ">>"
        }
        throw CocoaError(.fileWriteUnknown)
    }
}
