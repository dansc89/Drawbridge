import Foundation

/// Sheet references need a discipline and a number. Ordinary PDF page ordinals,
/// placeholder labels, and prose must never become document-wide search targets.
enum SheetReferencePolicy {
    private static let identifierRegex = try! NSRegularExpression(pattern: #"^[A-Z]{1,4}[._\-]?[0-9OIL]{1,3}(?:[._\-][0-9OIL]{1,3})?[A-Z]?$"#, options: [.caseInsensitive])
    static func isSheetIdentifier(_ token: String) -> Bool {
        guard token.rangeOfCharacter(from: .decimalDigits) != nil else { return false }
        return identifierRegex.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil
    }

    static func uniqueOCRSheetIdentifier(in text: String) -> String? {
        let parts = text.uppercased().components(separatedBy: .whitespacesAndNewlines)
        let tokens = Set(parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ":,;()[]")) }
            .filter(isSheetIdentifier))
        guard tokens.count == 1 else { return nil }
        return tokens.first
    }

    static func exactReferences(in text: String, knownTokens: Set<String>) -> [String] {
        let nsText = text as NSString
        return knownTokens.sorted().filter { token in
            guard isSheetIdentifier(token),
                  let regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: token), options: [.caseInsensitive]) else { return false }
            return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
                .contains { isWholeToken($0.range, in: nsText) }
        }
    }

    static func isWholeToken(_ range: NSRange, in text: NSString) -> Bool {
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= text.length else { return false }
        func isIdentifierCharacter(_ index: Int) -> Bool {
            let value = text.substring(with: NSRange(location: index, length: 1))
            return value.rangeOfCharacter(from: .alphanumerics) != nil
        }
        // Separators followed by more identifier characters belong to the same
        // reference (A1.1 must not match A1.1.0 or A1.1-REV).
        let separators = CharacterSet(charactersIn: "._-")
        if range.location >= 2,
           text.substring(with: NSRange(location: range.location - 1, length: 1)).rangeOfCharacter(from: separators) != nil,
           isIdentifierCharacter(range.location - 2) { return false }
        if NSMaxRange(range) + 1 < text.length,
           text.substring(with: NSRange(location: NSMaxRange(range), length: 1)).rangeOfCharacter(from: separators) != nil,
           isIdentifierCharacter(NSMaxRange(range) + 1) { return false }
        return (range.location == 0 || !isIdentifierCharacter(range.location - 1))
            && (NSMaxRange(range) == text.length || !isIdentifierCharacter(NSMaxRange(range)))
    }
}

/// Only OCR observations can enter this map. Duplicate sheet numbers are ambiguous
/// and cannot silently redirect references to the last page scanned.
struct OCRSheetTargetIndex {
    private(set) var targets: [String: Int] = [:]
    private var ambiguous = Set<String>()

    mutating func record(_ token: String, pageIndex: Int) {
        let key = token.uppercased()
        guard SheetReferencePolicy.isSheetIdentifier(key), !ambiguous.contains(key) else { return }
        if let existing = targets[key], existing != pageIndex {
            targets.removeValue(forKey: key)
            ambiguous.insert(key)
        } else {
            targets[key] = pageIndex
        }
    }
}
