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

/// Opaque chrome surfaces keep native selection drawing from overriding palette text.
/// Resolve within the chrome's appearance, never on the PDF subtree.
struct ChromeSelectionColors {
    let background: NSColor
    let foreground: NSColor
    let accent: NSColor

    init(active: Bool, appearance: NSAppearance) {
        var panel = NSColor.black, text = NSColor.white, marker = NSColor.white
        appearance.performAsCurrentDrawingAppearance {
            let theme = InterfaceTheme.current
            let base = (theme.color(for: "panel") ?? AppAppearance.panel).usingColorSpace(.sRGB)!
            marker = (theme.color(for: "accent") ?? .controlAccentColor).usingColorSpace(.sRGB)!
            func mix(_ a: NSColor, _ b: NSColor, _ amount: CGFloat) -> NSColor {
                NSColor(srgbRed: a.redComponent * (1 - amount) + b.redComponent * amount,
                        green: a.greenComponent * (1 - amount) + b.greenComponent * amount,
                        blue: a.blueComponent * (1 - amount) + b.blueComponent * amount, alpha: 1)
            }
            panel = active ? mix(base, marker, 0.12) : base
            let preferred = (theme.color(for: "foreground") ?? .labelColor).usingColorSpace(.sRGB)!
            // Native label colors can be translucent. Composite first, then correct
            // only as far as necessary (e.g. Solarized's deliberately muted text).
            text = mix(panel, preferred, preferred.alphaComponent)
            func luminance(_ c: NSColor) -> CGFloat {
                let v = [c.redComponent, c.greenComponent, c.blueComponent].map {
                    $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
                }
                return v[0] * 0.2126 + v[1] * 0.7152 + v[2] * 0.0722
            }
            func contrast(_ c: NSColor) -> CGFloat {
                let a = luminance(c), b = luminance(panel)
                return (max(a,b) + 0.05) / (min(a,b) + 0.05)
            }
            let black = NSColor.black.usingColorSpace(.sRGB)!
            let white = NSColor.white.usingColorSpace(.sRGB)!
            let endpoint = contrast(black) > contrast(white) ? black : white
            let original = text
            for step in 0...100 where contrast(text) < 4.5 {
                text = mix(original, endpoint, CGFloat(step) / 100)
            }
        }
        background = panel; foreground = text; accent = marker
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
