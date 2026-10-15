import AppKit

/// Optional chrome-only palettes. Missing/unknown preferences always inherit macOS.
enum InterfaceTheme: String, CaseIterable {
    case system
    case absolutelyDark = "absolutely-dark"
    case absolutelyLight = "absolutely-light"
    case ayuDark = "ayu-dark"
    // Preserve the original persisted dark-theme keys.
    case catppuccin
    case catppuccinLight = "catppuccin-light"
    case chatgptDark = "chatgpt-dark"
    case chatgptLight = "chatgpt-light"
    case codexDark = "codex-dark"
    case codexLight = "codex-light"
    case dracula
    case everforestDark = "everforest-dark"
    case everforestLight = "everforest-light"
    case githubDark = "github-dark"
    case githubLight = "github-light"
    case gruvboxDark = "gruvbox-dark"
    case gruvboxLight = "gruvbox-light"
    case linearDark = "linear-dark"
    case linearLight = "linear-light"
    case lobsterDark = "lobster-dark"
    case materialDark = "material-dark"
    case matrixDark = "matrix-dark"
    case monokaiDark = "monokai-dark"
    case nightOwlDark = "night-owl-dark"
    case nord
    case notionDark = "notion-dark"
    case notionLight = "notion-light"
    case ogDark = "og-dark"
    case oneDark = "one-dark"
    case oneLight = "one-light"
    case oscurangeDark = "oscurange-dark"
    case proofLight = "proof-light"
    case raycastDark = "raycast-dark"
    case raycastLight = "raycast-light"
    case rosePineDark = "rose-pine-dark"
    case rosePineLight = "rose-pine-light"
    case sentryDark = "sentry-dark"
    case solarizedDark = "solarized-dark"
    case solarizedLight = "solarized-light"
    case templeDark = "temple-dark"
    case tokyoNightDark = "tokyo-night-dark"
    case vercelDark = "vercel-dark"
    case vercelLight = "vercel-light"
    case vscodePlusDark = "vscode-plus-dark"
    case vscodePlusLight = "vscode-plus-light"
    case xcodeDark = "xcode-dark"
    case xcodeLight = "xcode-light"

    static let defaultsKey = "DrawbridgeInterfaceTheme"
    static let didChange = Notification.Name("DrawbridgeInterfaceThemeDidChange")
    static let presets: [Self] = allCases.filter { $0 != .system }.sorted { $0.title < $1.title }
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system }
    var title: String { palette?.title ?? "Follow macOS" }
    var nativeAppearance: NSAppearance? {
        guard let palette else { return nil }
        return NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
    }
    @MainActor static func select(_ theme: Self) {
        UserDefaults.standard.set(theme.rawValue, forKey: defaultsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
    func color(for role: String) -> NSColor? {
        guard let palette else { return nil }
        let rgb: UInt32
        switch role {
        case "chrome", "canvas": rgb = palette.background
        case "foreground": rgb = palette.foreground
        case "accent": rgb = palette.accent
        case "panel": rgb = palette.panel
        case "sidebar": rgb = palette.sidebar
        default: return nil // PDF page, annotation and selection colors never use palettes.
        }
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
        // only their chrome subtrees receive the chosen native control appearance.
        window?.appearance = InterfaceTheme.current.nativeAppearance
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
