import AppKit

/// Optional chrome-only palettes. Missing/unknown preferences always inherit macOS.
enum InterfaceTheme: String, CaseIterable {
    case system, dracula, nord, catppuccin
    static let defaultsKey = "DrawbridgeInterfaceTheme"
    static let didChange = Notification.Name("DrawbridgeInterfaceThemeDidChange")
    static let presets: [Self] = [.dracula, .nord, .catppuccin]
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system }
    var title: String {
        switch self {
        case .system: return "Follow macOS"
        case .dracula: return "Dracula"
        case .nord: return "Nord"
        case .catppuccin: return "Catppuccin"
        }
    }
    @MainActor static func select(_ theme: Self) {
        UserDefaults.standard.set(theme.rawValue, forKey: defaultsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
    func color(for role: String) -> NSColor? {
        let colors: [UInt32]
        switch self {
        case .system: return nil
        case .dracula: colors = [0x282A36, 0x343746, 0x21222C]
        case .nord: colors = [0x2E3440, 0x3B4252, 0x434C5E]
        case .catppuccin: colors = [0x1E1E2E, 0x313244, 0x181825]
        }
        let index: Int
        switch role {
        case "chrome", "canvas": index = 0
        case "panel": index = 1
        case "sidebar": index = 2
        default: return nil // PDF page and annotation colors never use palettes.
        }
        let rgb = colors[index]
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

/// Semantic native controls, focus and selection remain AppKit-owned.
enum AppAppearance {
    static let chrome = adaptive("chrome", light: 0.91, dark: 0.08)
    static let panel = adaptive("panel", light: 0.98, dark: 0.12)
    static let sidebar = adaptive("sidebar", light: 0.94, dark: 0.14)
    static let canvas = adaptive("canvas", light: 0.82, dark: 0.07)

    @MainActor static func applyInterface(to window: NSWindow?) {
        // Settings contains no PDF. Editor windows keep inherited appearance;
        // only their chrome subtrees receive the dark native control appearance.
        window?.appearance = InterfaceTheme.current == .system ? nil : NSAppearance(named: .darkAqua)
        window?.backgroundColor = panel
    }

    private static func adaptive(_ name: String, light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: NSColor.Name("Drawbridge.\(name)")) { appearance in
            if let custom = InterfaceTheme.current.color(for: name) { return custom }
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(calibratedWhite: isDark ? dark : light, alpha: 1)
        }
    }
}
