import Foundation

enum NativeDrawingProgramTokens {
    struct Token { let range: Range<Int>; let text: String; let operand: Bool }
    static func read(_ data: Data) throws -> [Token] {
        let bytes = Array(data); var i = 0
        func space(_ b: UInt8) -> Bool { [0,9,10,12,13,32].contains(b) }
        func delimiter(_ b: UInt8) -> Bool { space(b) || [40,41,60,62,91,93,123,125,47,37].contains(b) }
        func fail(_ detail: String) -> NativePDFLayerMutation.Failure { .unsupported(detail) }
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
        var result: [Token] = []
        while true {
            skip(); if i >= bytes.count { break }
            guard result.count < 2_000_000 else { throw fail("drawing program exceeds the editing limit") }
            let next = try token()
            guard next.text != "BI" else { throw fail("inline images in this drawing program") }
            result.append(next)
        }
        return result
    }
}
