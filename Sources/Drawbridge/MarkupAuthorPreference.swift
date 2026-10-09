import Foundation

/// Per-user preference, independent of markup identity and document ownership.
enum MarkupAuthorPreference {
    static let defaultsKey = "markupAuthorName"
    static func name(defaults: UserDefaults = .standard, accountName: String = NSFullUserName()) -> String {
        let configured = defaults.string(forKey: defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !configured.isEmpty { return configured }
        let account = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        return account.isEmpty ? NSUserName() : account
    }
    static var currentName: String { name() }
}
