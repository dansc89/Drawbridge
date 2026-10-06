import Foundation

/// PDF real numbers do not support exponent notation. qpdf's JSON updater may
/// interpret an exponent-form JSON number as zero when constructing a PDF real.
/// Expand numeric tokens exactly, without rounding or touching quoted strings.
enum PDFJSONPatchEncoder {
    static func data(withJSONObject object: Any, options: JSONSerialization.WritingOptions = []) throws -> Data {
        try expandingExponents(in: JSONSerialization.data(withJSONObject: object, options: options))
    }

    static func expandingExponents(in data: Data) throws -> Data {
        let bytes = Array(data)
        var output = Data(); output.reserveCapacity(bytes.count)
        var index = 0, quoted = false, escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                output.append(byte)
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                index += 1
            } else if byte == 34 {
                quoted = true; output.append(byte); index += 1
            } else if byte == 45 || (48...57).contains(byte) {
                let start = index
                while index < bytes.count, (48...57).contains(bytes[index]) || [45,43,46,69,101].contains(bytes[index]) { index += 1 }
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                guard let e = token.firstIndex(where: { $0 == "e" || $0 == "E" }) else {
                    output.append(contentsOf: bytes[start..<index]); continue
                }
                guard let exponent = Int(token[token.index(after: e)...]), exponent >= -4096, exponent <= 4096 else { throw CocoaError(.fileWriteUnknown) }
                let negative = token.first == "-"
                let coefficient = token[token.index(token.startIndex, offsetBy: negative ? 1 : 0)..<e]
                let parts = coefficient.split(separator: ".", omittingEmptySubsequences: false)
                let digits = parts.joined()
                let position = parts[0].count + exponent
                let expanded: String
                if position <= 0 { expanded = "0." + String(repeating: "0", count: -position) + digits }
                else if position >= digits.count { expanded = digits + String(repeating: "0", count: position - digits.count) }
                else {
                    let split = digits.index(digits.startIndex, offsetBy: position)
                    expanded = String(digits[..<split]) + "." + digits[split...]
                }
                output.append(contentsOf: ((negative ? "-" : "") + expanded).utf8)
            } else {
                output.append(byte); index += 1
            }
        }
        return output
    }
}
