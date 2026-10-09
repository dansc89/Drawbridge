import AppKit

/// Interface colors follow macOS while preserving the existing dark palette.
enum AppAppearance {
    static let chrome = adaptive("chrome", light: 0.91, dark: 0.08)
    static let panel = adaptive("panel", light: 0.98, dark: 0.12)
    static let sidebar = adaptive("sidebar", light: 0.94, dark: 0.14)
    static let canvas = adaptive("canvas", light: 0.82, dark: 0.07)

    private static func adaptive(_ name: String, light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: NSColor.Name("Drawbridge.\(name)")) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(calibratedWhite: isDark ? dark : light, alpha: 1)
        }
    }
}
