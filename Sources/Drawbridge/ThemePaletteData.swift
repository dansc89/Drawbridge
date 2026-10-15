import AppKit

/// Exact chrome tokens from ChatGPT/Codex 26.1007.30912 (20156).
/// Only color constants are bundled; no extracted application code or assets.
struct InterfacePalette {
    let title: String
    let isDark: Bool
    let background: UInt32
    let foreground: UInt32
    let accent: UInt32
    let panel: UInt32
    let sidebar: UInt32
}

extension InterfaceTheme {
    var palette: InterfacePalette? { Self.paletteData[self] }
    static let paletteData: [Self: InterfacePalette] = [
        .absolutelyDark: InterfacePalette(title: "Absolutely (Dark)", isDark: true, background: 0x2d2d2b, foreground: 0xf9f9f7, accent: 0xcc7d5e, panel: 0x373735, sidebar: 0x262624),
        .absolutelyLight: InterfacePalette(title: "Absolutely (Light)", isDark: false, background: 0xf9f9f7, foreground: 0x2d2d2b, accent: 0xcc7d5e, panel: 0xfafaf8, sidebar: 0xf1f1ef),
        .ayuDark: InterfacePalette(title: "Ayu (Dark)", isDark: true, background: 0x10141c, foreground: 0xbfbdb6, accent: 0xe6b450, panel: 0x181c23, sidebar: 0x0d1118),
        .catppuccin: InterfacePalette(title: "Catppuccin (Dark)", isDark: true, background: 0x1e1e2e, foreground: 0xcdd6f4, accent: 0xcba6f7, panel: 0x262738, sidebar: 0x191927),
        .catppuccinLight: InterfacePalette(title: "Catppuccin (Light)", isDark: false, background: 0xeff1f5, foreground: 0x4c4f69, accent: 0x8839ef, panel: 0xf2f4f7, sidebar: 0xe8ebef),
        .chatgptDark: InterfacePalette(title: "ChatGPT Default (Dark)", isDark: true, background: 0x000000, foreground: 0xededed, accent: 0x3a83f7, panel: 0x0b0b0b, sidebar: 0x000000),
        .chatgptLight: InterfacePalette(title: "ChatGPT Default (Light)", isDark: false, background: 0xfcfcfc, foreground: 0x0d0d0d, accent: 0x3a83f7, panel: 0xfdfdfd, sidebar: 0xf2f2f2),
        .codexDark: InterfacePalette(title: "Codex (Dark)", isDark: true, background: 0x111111, foreground: 0xfcfcfc, accent: 0x0169cc, panel: 0x1c1c1c, sidebar: 0x0e0e0e),
        .codexLight: InterfacePalette(title: "Codex (Light)", isDark: false, background: 0xffffff, foreground: 0x0d0d0d, accent: 0x0169cc, panel: 0xffffff, sidebar: 0xf5f5f5),
        .dracula: InterfacePalette(title: "Dracula (Dark)", isDark: true, background: 0x282a36, foreground: 0xf8f8f2, accent: 0xff79c6, panel: 0x32343f, sidebar: 0x22232d),
        .everforestDark: InterfacePalette(title: "Everforest (Dark)", isDark: true, background: 0x2d353b, foreground: 0xd3c6aa, accent: 0xa7c080, panel: 0x353c40, sidebar: 0x262d32),
        .everforestLight: InterfacePalette(title: "Everforest (Light)", isDark: false, background: 0xfdf6e3, foreground: 0x5c6a72, accent: 0x93b259, panel: 0xfdf8e8, sidebar: 0xf7f0de),
        .githubDark: InterfacePalette(title: "GitHub (Dark)", isDark: true, background: 0x0d1117, foreground: 0xe6edf3, accent: 0x1f6feb, panel: 0x171c22, sidebar: 0x0b0e13),
        .githubLight: InterfacePalette(title: "GitHub (Light)", isDark: false, background: 0xffffff, foreground: 0x1f2328, accent: 0x0969da, panel: 0xffffff, sidebar: 0xf6f6f6),
        .gruvboxDark: InterfacePalette(title: "Gruvbox (Dark)", isDark: true, background: 0x282828, foreground: 0xebdbb2, accent: 0x458588, panel: 0x31312f, sidebar: 0x222222),
        .gruvboxLight: InterfacePalette(title: "Gruvbox (Light)", isDark: false, background: 0xfbf1c7, foreground: 0x3c3836, accent: 0x458588, panel: 0xfcf4d1, sidebar: 0xf3eac1),
        .linearDark: InterfacePalette(title: "Linear (Dark)", isDark: true, background: 0x0f0f11, foreground: 0xe3e4e6, accent: 0x606acc, panel: 0x19191b, sidebar: 0x0d0d0e),
        .linearLight: InterfacePalette(title: "Linear (Light)", isDark: false, background: 0xfcfcfd, foreground: 0x1b1b1b, accent: 0x5e6ad2, panel: 0xfdfdfd, sidebar: 0xf3f3f4),
        .lobsterDark: InterfacePalette(title: "Lobster (Dark)", isDark: true, background: 0x111827, foreground: 0xe4e4e7, accent: 0xff5c5c, panel: 0x1b2230, sidebar: 0x0e1421),
        .materialDark: InterfacePalette(title: "Material (Dark)", isDark: true, background: 0x212121, foreground: 0xeeffff, accent: 0x80cbc4, panel: 0x2b2c2c, sidebar: 0x1c1c1c),
        .matrixDark: InterfacePalette(title: "Matrix (Dark)", isDark: true, background: 0x040805, foreground: 0xb8ffca, accent: 0x1eff5a, panel: 0x0d140e, sidebar: 0x030704),
        .monokaiDark: InterfacePalette(title: "Monokai (Dark)", isDark: true, background: 0x272822, foreground: 0xf8f8f2, accent: 0x99947c, panel: 0x31322c, sidebar: 0x21221d),
        .nightOwlDark: InterfacePalette(title: "Night Owl (Dark)", isDark: true, background: 0x011627, foreground: 0xd6deeb, accent: 0x44596b, panel: 0x0b2030, sidebar: 0x011221),
        .nord: InterfacePalette(title: "Nord (Dark)", isDark: true, background: 0x2e3440, foreground: 0xd8dee9, accent: 0x88c0d0, panel: 0x363c48, sidebar: 0x272c36),
        .notionDark: InterfacePalette(title: "Notion (Dark)", isDark: true, background: 0x191919, foreground: 0xd9d9d8, accent: 0x3183d8, panel: 0x222222, sidebar: 0x151515),
        .notionLight: InterfacePalette(title: "Notion (Light)", isDark: false, background: 0xffffff, foreground: 0x37352f, accent: 0x3183d8, panel: 0xffffff, sidebar: 0xf7f7f7),
        .ogDark: InterfacePalette(title: "OG (Dark)", isDark: true, background: 0x343541, foreground: 0xd1d5db, accent: 0x10a37f, panel: 0x3c3d48, sidebar: 0x2c2d37),
        .oneDark: InterfacePalette(title: "One (Dark)", isDark: true, background: 0x282c34, foreground: 0xabb2bf, accent: 0x4d78cc, panel: 0x2e323b, sidebar: 0x22252c),
        .oneLight: InterfacePalette(title: "One (Light)", isDark: false, background: 0xfafafa, foreground: 0x383a42, accent: 0x526fff, panel: 0xfbfbfb, sidebar: 0xf2f2f3),
        .oscurangeDark: InterfacePalette(title: "Oscurange (Dark)", isDark: true, background: 0x0b0b0f, foreground: 0xe6e6e6, accent: 0xf9b98c, panel: 0x161619, sidebar: 0x09090d),
        .proofLight: InterfacePalette(title: "Proof (Light)", isDark: false, background: 0xf5f3ed, foreground: 0x2f312d, accent: 0x3d755d, panel: 0xf7f5f0, sidebar: 0xedebe5),
        .raycastDark: InterfacePalette(title: "Raycast (Dark)", isDark: true, background: 0x101010, foreground: 0xfefefe, accent: 0xff6363, panel: 0x1b1b1b, sidebar: 0x0d0d0d),
        .raycastLight: InterfacePalette(title: "Raycast (Light)", isDark: false, background: 0xffffff, foreground: 0x030303, accent: 0xff6363, panel: 0xffffff, sidebar: 0xf5f5f5),
        .rosePineDark: InterfacePalette(title: "Rose Pine (Dark)", isDark: true, background: 0x232136, foreground: 0xe0def4, accent: 0xea9a97, panel: 0x2c2a3f, sidebar: 0x1d1c2d),
        .rosePineLight: InterfacePalette(title: "Rose Pine (Light)", isDark: false, background: 0xfaf4ed, foreground: 0x575279, accent: 0xd7827e, panel: 0xfbf6f0, sidebar: 0xf3eee8),
        .sentryDark: InterfacePalette(title: "Sentry (Dark)", isDark: true, background: 0x2d2935, foreground: 0xe6dff9, accent: 0x7055f6, panel: 0x36323e, sidebar: 0x26222d),
        .solarizedDark: InterfacePalette(title: "Solarized (Dark)", isDark: true, background: 0x002b36, foreground: 0x839496, accent: 0xd30102, panel: 0x06303b, sidebar: 0x00242d),
        .solarizedLight: InterfacePalette(title: "Solarized (Light)", isDark: false, background: 0xfdf6e3, foreground: 0x657b83, accent: 0xb58900, panel: 0xfdf8e8, sidebar: 0xf7f1df),
        .templeDark: InterfacePalette(title: "Temple (Dark)", isDark: true, background: 0x02120c, foreground: 0xc7e6da, accent: 0xe4f222, panel: 0x0b1c16, sidebar: 0x020f0a),
        .tokyoNightDark: InterfacePalette(title: "Tokyo Night (Dark)", isDark: true, background: 0x1a1b26, foreground: 0xa9b1d6, accent: 0x3d59a1, panel: 0x21222e, sidebar: 0x161720),
        .vercelDark: InterfacePalette(title: "Vercel (Dark)", isDark: true, background: 0x000000, foreground: 0xededed, accent: 0x006efe, panel: 0x0a0a0a, sidebar: 0x000000),
        .vercelLight: InterfacePalette(title: "Vercel (Light)", isDark: false, background: 0xffffff, foreground: 0x171717, accent: 0x006aff, panel: 0xffffff, sidebar: 0xf7f7f7),
        .vscodePlusDark: InterfacePalette(title: "VS Code Plus (Dark)", isDark: true, background: 0x1e1e1e, foreground: 0xd4d4d4, accent: 0x007acc, panel: 0x272727, sidebar: 0x191919),
        .vscodePlusLight: InterfacePalette(title: "VS Code Plus (Light)", isDark: false, background: 0xffffff, foreground: 0x000000, accent: 0x007acc, panel: 0xffffff, sidebar: 0xf5f5f5),
        .xcodeDark: InterfacePalette(title: "Xcode (Dark)", isDark: true, background: 0x1f1f24, foreground: 0xffffff, accent: 0x5482ff, panel: 0x2a2a2f, sidebar: 0x1a1a1e),
        .xcodeLight: InterfacePalette(title: "Xcode (Light)", isDark: false, background: 0xffffff, foreground: 0x000000, accent: 0x0e0eff, panel: 0xffffff, sidebar: 0xf5f5f5),
    ]
}
