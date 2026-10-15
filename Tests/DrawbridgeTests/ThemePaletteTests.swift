import XCTest
import AppKit
import PDFKit
@testable import Drawbridge

@MainActor final class ThemePaletteTests: XCTestCase {
    // Independent expected app-chrome tokens extracted from the shipped catalog.
    private let expected: [(key: String, title: String, dark: Bool, colors: [UInt32])] = [
        ("absolutely-dark", "Absolutely (Dark)", true, [0x2d2d2b, 0xf9f9f7, 0xcc7d5e, 0x373735, 0x262624]),
        ("absolutely-light", "Absolutely (Light)", false, [0xf9f9f7, 0x2d2d2b, 0xcc7d5e, 0xfafaf8, 0xf1f1ef]),
        ("ayu-dark", "Ayu (Dark)", true, [0x10141c, 0xbfbdb6, 0xe6b450, 0x181c23, 0x0d1118]),
        ("catppuccin", "Catppuccin (Dark)", true, [0x1e1e2e, 0xcdd6f4, 0xcba6f7, 0x262738, 0x191927]),
        ("catppuccin-light", "Catppuccin (Light)", false, [0xeff1f5, 0x4c4f69, 0x8839ef, 0xf2f4f7, 0xe8ebef]),
        ("chatgpt-dark", "ChatGPT Default (Dark)", true, [0x000000, 0xededed, 0x3a83f7, 0x0b0b0b, 0x000000]),
        ("chatgpt-light", "ChatGPT Default (Light)", false, [0xfcfcfc, 0x0d0d0d, 0x3a83f7, 0xfdfdfd, 0xf2f2f2]),
        ("codex-dark", "Codex (Dark)", true, [0x111111, 0xfcfcfc, 0x0169cc, 0x1c1c1c, 0x0e0e0e]),
        ("codex-light", "Codex (Light)", false, [0xffffff, 0x0d0d0d, 0x0169cc, 0xffffff, 0xf5f5f5]),
        ("dracula", "Dracula (Dark)", true, [0x282a36, 0xf8f8f2, 0xff79c6, 0x32343f, 0x22232d]),
        ("everforest-dark", "Everforest (Dark)", true, [0x2d353b, 0xd3c6aa, 0xa7c080, 0x353c40, 0x262d32]),
        ("everforest-light", "Everforest (Light)", false, [0xfdf6e3, 0x5c6a72, 0x93b259, 0xfdf8e8, 0xf7f0de]),
        ("github-dark", "GitHub (Dark)", true, [0x0d1117, 0xe6edf3, 0x1f6feb, 0x171c22, 0x0b0e13]),
        ("github-light", "GitHub (Light)", false, [0xffffff, 0x1f2328, 0x0969da, 0xffffff, 0xf6f6f6]),
        ("gruvbox-dark", "Gruvbox (Dark)", true, [0x282828, 0xebdbb2, 0x458588, 0x31312f, 0x222222]),
        ("gruvbox-light", "Gruvbox (Light)", false, [0xfbf1c7, 0x3c3836, 0x458588, 0xfcf4d1, 0xf3eac1]),
        ("linear-dark", "Linear (Dark)", true, [0x0f0f11, 0xe3e4e6, 0x606acc, 0x19191b, 0x0d0d0e]),
        ("linear-light", "Linear (Light)", false, [0xfcfcfd, 0x1b1b1b, 0x5e6ad2, 0xfdfdfd, 0xf3f3f4]),
        ("lobster-dark", "Lobster (Dark)", true, [0x111827, 0xe4e4e7, 0xff5c5c, 0x1b2230, 0x0e1421]),
        ("material-dark", "Material (Dark)", true, [0x212121, 0xeeffff, 0x80cbc4, 0x2b2c2c, 0x1c1c1c]),
        ("matrix-dark", "Matrix (Dark)", true, [0x040805, 0xb8ffca, 0x1eff5a, 0x0d140e, 0x030704]),
        ("monokai-dark", "Monokai (Dark)", true, [0x272822, 0xf8f8f2, 0x99947c, 0x31322c, 0x21221d]),
        ("night-owl-dark", "Night Owl (Dark)", true, [0x011627, 0xd6deeb, 0x44596b, 0x0b2030, 0x011221]),
        ("nord", "Nord (Dark)", true, [0x2e3440, 0xd8dee9, 0x88c0d0, 0x363c48, 0x272c36]),
        ("notion-dark", "Notion (Dark)", true, [0x191919, 0xd9d9d8, 0x3183d8, 0x222222, 0x151515]),
        ("notion-light", "Notion (Light)", false, [0xffffff, 0x37352f, 0x3183d8, 0xffffff, 0xf7f7f7]),
        ("og-dark", "OG (Dark)", true, [0x343541, 0xd1d5db, 0x10a37f, 0x3c3d48, 0x2c2d37]),
        ("one-dark", "One (Dark)", true, [0x282c34, 0xabb2bf, 0x4d78cc, 0x2e323b, 0x22252c]),
        ("one-light", "One (Light)", false, [0xfafafa, 0x383a42, 0x526fff, 0xfbfbfb, 0xf2f2f3]),
        ("oscurange-dark", "Oscurange (Dark)", true, [0x0b0b0f, 0xe6e6e6, 0xf9b98c, 0x161619, 0x09090d]),
        ("proof-light", "Proof (Light)", false, [0xf5f3ed, 0x2f312d, 0x3d755d, 0xf7f5f0, 0xedebe5]),
        ("raycast-dark", "Raycast (Dark)", true, [0x101010, 0xfefefe, 0xff6363, 0x1b1b1b, 0x0d0d0d]),
        ("raycast-light", "Raycast (Light)", false, [0xffffff, 0x030303, 0xff6363, 0xffffff, 0xf5f5f5]),
        ("rose-pine-dark", "Rose Pine (Dark)", true, [0x232136, 0xe0def4, 0xea9a97, 0x2c2a3f, 0x1d1c2d]),
        ("rose-pine-light", "Rose Pine (Light)", false, [0xfaf4ed, 0x575279, 0xd7827e, 0xfbf6f0, 0xf3eee8]),
        ("sentry-dark", "Sentry (Dark)", true, [0x2d2935, 0xe6dff9, 0x7055f6, 0x36323e, 0x26222d]),
        ("solarized-dark", "Solarized (Dark)", true, [0x002b36, 0x839496, 0xd30102, 0x06303b, 0x00242d]),
        ("solarized-light", "Solarized (Light)", false, [0xfdf6e3, 0x657b83, 0xb58900, 0xfdf8e8, 0xf7f1df]),
        ("temple-dark", "Temple (Dark)", true, [0x02120c, 0xc7e6da, 0xe4f222, 0x0b1c16, 0x020f0a]),
        ("tokyo-night-dark", "Tokyo Night (Dark)", true, [0x1a1b26, 0xa9b1d6, 0x3d59a1, 0x21222e, 0x161720]),
        ("vercel-dark", "Vercel (Dark)", true, [0x000000, 0xededed, 0x006efe, 0x0a0a0a, 0x000000]),
        ("vercel-light", "Vercel (Light)", false, [0xffffff, 0x171717, 0x006aff, 0xffffff, 0xf7f7f7]),
        ("vscode-plus-dark", "VS Code Plus (Dark)", true, [0x1e1e1e, 0xd4d4d4, 0x007acc, 0x272727, 0x191919]),
        ("vscode-plus-light", "VS Code Plus (Light)", false, [0xffffff, 0x000000, 0x007acc, 0xffffff, 0xf5f5f5]),
        ("xcode-dark", "Xcode (Dark)", true, [0x1f1f24, 0xffffff, 0x5482ff, 0x2a2a2f, 0x1a1a1e]),
        ("xcode-light", "Xcode (Light)", false, [0xffffff, 0x000000, 0x0e0eff, 0xffffff, 0xf5f5f5]),
    ]
    override func setUp() {
        super.setUp()
        let old = UserDefaults.standard.object(forKey: InterfaceTheme.defaultsKey)
        addTeardownBlock {
            if let old { UserDefaults.standard.set(old, forKey: InterfaceTheme.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: InterfaceTheme.defaultsKey) }
        }
    }
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    private func assertColor(_ color: NSColor?, _ rgb: UInt32, file: StaticString = #filePath, line: UInt = #line) {
        guard let c = color?.usingColorSpace(.sRGB) else { XCTFail("Missing palette color", file: file, line: line); return }
        XCTAssertEqual(c.redComponent, CGFloat((rgb >> 16) & 255) / 255, accuracy: 0.00001, file: file, line: line)
        XCTAssertEqual(c.greenComponent, CGFloat((rgb >> 8) & 255) / 255, accuracy: 0.00001, file: file, line: line)
        XCTAssertEqual(c.blueComponent, CGFloat(rgb & 255) / 255, accuracy: 0.00001, file: file, line: line)
    }
    func testLegacyPaletteForegroundAndSafeSettingsAccentAreApplied() throws {
        _ = NSApplication.shared
        InterfaceTheme.select(.system)
        let editor = MainViewController()
        _ = editor.view
        let nativeForeground = editor.markupsCountLabel.textColor
        let settings = SettingsWindowController(editor: editor)
        settings.prepare(section: .interface)
        let window = try XCTUnwrap(settings.window)
        defer { window.close() }
        let navigation = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Interface" })
        let nativeBezel = navigation.bezelColor
        InterfaceTheme.select(.dracula)
        settings.prepare(section: .interface)
        assertColor(editor.markupsCountLabel.textColor, 0xf8f8f2)
        assertColor(navigation.bezelColor, 0xff79c6)
        InterfaceTheme.select(.system)
        settings.prepare(section: .interface)
        XCTAssertEqual(editor.markupsCountLabel.textColor, nativeForeground)
        XCTAssertEqual(navigation.bezelColor, nativeBezel)
    }
    func testSettingsSidebarTracksNativeAppearanceChanges() throws {
        _ = NSApplication.shared
        InterfaceTheme.select(.system)
        let settings = SettingsWindowController(editor: MainViewController())
        settings.prepare(section: .interface)
        let window = try XCTUnwrap(settings.window)
        defer { window.close() }
        let button = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Interface" })
        let sidebar = try XCTUnwrap(button.superview)
        for (appearance, gray) in [(NSAppearance.Name.aqua, CGFloat(0.94)), (.darkAqua, CGFloat(0.14)), (.aqua, CGFloat(0.94))] {
            window.appearance = NSAppearance(named: appearance)
            sidebar.viewDidChangeEffectiveAppearance()
            let color = try XCTUnwrap(sidebar.layer?.backgroundColor)
            let expected = NSColor(calibratedWhite: gray, alpha: 1).cgColor
            XCTAssertEqual(color, expected)
        }
    }
    func testCompleteCatalogHasExactShippedChromeColors() throws {
        XCTAssertEqual(InterfaceTheme.presets.count, 46, "44 Codex variants plus two separate ChatGPT defaults")
        XCTAssertEqual(InterfaceTheme.presets.map(\.title), expected.map(\.title).sorted())
        XCTAssertEqual(Set(InterfaceTheme.presets.map(\.rawValue)).count, 46)
        for fixture in expected {
            let theme = try XCTUnwrap(InterfaceTheme(rawValue: fixture.key), fixture.title)
            XCTAssertEqual(theme.title, fixture.title)
            for (role, rgb) in zip(["chrome", "foreground", "accent", "panel", "sidebar"], fixture.colors) {
                assertColor(theme.color(for: role), rgb)
            }
            assertColor(theme.color(for: "canvas"), fixture.colors[0])
            for role in ["page", "annotation", "markup", "selection"] { XCTAssertNil(theme.color(for: role)) }
        }
        XCTAssertEqual(InterfaceTheme(rawValue: "dracula"), .dracula)
        XCTAssertEqual(InterfaceTheme(rawValue: "nord"), .nord)
        XCTAssertEqual(InterfaceTheme(rawValue: "catppuccin"), .catppuccin)
        XCTAssertNil(InterfaceTheme.system.color(for: "chrome"))
    }
    func testSettingsMenuSelectsPersistsAndReopensEveryVariantWithNativeAppearance() throws {
        let editor = MainViewController()
        let settings = SettingsWindowController(editor: editor)
        UserDefaults.standard.set("system", forKey: InterfaceTheme.defaultsKey)
        settings.prepare(section: .interface)
        let window = try XCTUnwrap(settings.window)
        defer { window.close() }
        func popup(_ id: String, _ w: NSWindow) throws -> NSPopUpButton {
            try XCTUnwrap(descendants(w.contentView!).first { $0.identifier?.rawValue == id } as? NSPopUpButton)
        }
        let mode = try popup("interfaceMode", window)
        let menu = try popup("interfacePreset", window)
        XCTAssertEqual(menu.itemTitles, expected.map(\.title).sorted())
        XCTAssertFalse(menu.isEnabled)
        mode.selectItem(at: 1)
        NSApp.sendAction(mode.action!, to: mode.target, from: mode)
        for fixture in expected {
            guard let index = menu.itemTitles.firstIndex(of: fixture.title) else { XCTFail("Missing menu choice: \(fixture.title)"); continue }
            menu.selectItem(at: index)
            NSApp.sendAction(menu.action!, to: menu.target, from: menu)
            XCTAssertEqual(UserDefaults.standard.string(forKey: InterfaceTheme.defaultsKey), fixture.key)
            XCTAssertEqual(InterfaceTheme.current.rawValue, fixture.key)
            XCTAssertEqual(window.appearance?.name, fixture.dark ? .darkAqua : .aqua)
            let reopened = SettingsWindowController(editor: editor)
            reopened.prepare(section: .interface)
            XCTAssertEqual(try popup("interfacePreset", reopened.window!).titleOfSelectedItem, fixture.title)
            reopened.window?.close()
        }
        mode.selectItem(at: 0)
        NSApp.sendAction(mode.action!, to: mode.target, from: mode)
        XCTAssertEqual(InterfaceTheme.current, .system)
        XCTAssertNil(window.appearance)
        XCTAssertFalse(menu.isEnabled)
    }
    func testEditorChromeUsesVariantAppearanceWithoutChangingPDFOrSemanticControls() throws {
        let editor = MainViewController()
        _ = editor.view
        let page = PDFPage()
        let annotation = PDFAnnotation(bounds: NSRect(x: 10, y: 10, width: 30, height: 30), forType: .square, withProperties: nil)
        annotation.color = .systemRed
        annotation.interiorColor = .systemYellow
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        editor.pdfView.document = document
        let color = annotation.color, interior = annotation.interiorColor
        let root = editor.view.appearance
        let disabled = NSButton(title: "Disabled", target: nil, action: nil)
        disabled.isEnabled = false
        editor.statusBar.addSubview(disabled)
        let tint = disabled.contentTintColor
        for fixture in expected {
            guard let theme = InterfaceTheme(rawValue: fixture.key) else { XCTFail("Missing variant: \(fixture.key)"); continue }
            InterfaceTheme.select(theme)
            XCTAssertEqual(editor.statusBar.appearance?.name, fixture.dark ? .darkAqua : .aqua)
            XCTAssertEqual(editor.markupsPanel.appearance?.name, fixture.dark ? .darkAqua : .aqua)
            XCTAssertEqual(editor.view.appearance, root)
            XCTAssertNil(editor.pdfView.appearance)
            XCTAssertTrue(editor.pdfView.document === document)
            XCTAssertEqual(annotation.color, color)
            XCTAssertEqual(annotation.interiorColor, interior)
            XCTAssertFalse(disabled.isEnabled)
            XCTAssertEqual(disabled.contentTintColor, tint)
            assertColor(editor.pdfView.backgroundColor, fixture.colors[0])
        }
        InterfaceTheme.select(.system)
        XCTAssertNil(editor.statusBar.appearance)
        XCTAssertNil(editor.markupsPanel.appearance)
        XCTAssertEqual(editor.view.appearance, root)
    }
}
