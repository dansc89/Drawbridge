import XCTest
import AppKit
import PDFKit
@testable import Drawbridge

@MainActor final class SettingsUITests: XCTestCase {
    func testApplicationMenuHasOneSettingsCommand() throws {
        _ = NSApplication.shared
        let oldMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = oldMenu }
        let delegate = AppDelegate()
        let controller = MainViewController()
        delegate.setupMainMenu(controller: controller)
        let menu = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu)
        let item = try XCTUnwrap(menu.items.first { $0.keyEquivalent == "," })
        XCTAssertEqual(item.title, "Settings…")
        XCTAssertTrue(item.target === controller)
        XCTAssertFalse(menu.items.contains { ["Keyboard Shortcuts…", "Markup Author…", "Performance Settings…"].contains($0.title) })
    }

    func testSettingsWindowIsReusableAndContainsEverySection() throws {
        _ = NSApplication.shared
        let editor = MainViewController()
        let settings = SettingsWindowController(editor: editor)
        settings.prepare()
        let window = try XCTUnwrap(settings.window)
        defer { window.close() }
        XCTAssertFalse(window.isVisible)
        for section in SettingsWindowController.Section.allCases {
            settings.prepare(section: section)
            XCTAssertTrue(settings.window === window)
            XCTAssertTrue(descendants(window.contentView!).contains { ($0 as? NSTextField)?.stringValue == section.rawValue })
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testLiveThemeSwitchRestoresNativeChromeAndPreservesMarkup() throws {
        let old = UserDefaults.standard.object(forKey: InterfaceTheme.defaultsKey)
        defer {
            if let old { UserDefaults.standard.set(old, forKey: InterfaceTheme.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: InterfaceTheme.defaultsKey) }
        }
        UserDefaults.standard.removeObject(forKey: InterfaceTheme.defaultsKey)
        XCTAssertEqual(InterfaceTheme.current, .system)
        UserDefaults.standard.set("unknown-theme", forKey: InterfaceTheme.defaultsKey)
        XCTAssertEqual(InterfaceTheme.current, .system)
        let editor = MainViewController()
        _ = editor.view
        let annotation = PDFAnnotation(bounds: NSRect(x: 1, y: 2, width: 20, height: 30), forType: .square, withProperties: nil)
        annotation.color = .systemRed
        let page = PDFPage()
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        editor.pdfView.document = document
        let canvasColor = editor.pdfView.backgroundColor
        let rootAppearance = editor.view.appearance
        let markupColor = annotation.color
        for theme in InterfaceTheme.presets {
            InterfaceTheme.select(theme)
            XCTAssertEqual(editor.markupsPanel.appearance?.name, .darkAqua, "Markup list is chrome, not PDF content")
            XCTAssertEqual(editor.statusBar.appearance?.name, .darkAqua)
            XCTAssertEqual(editor.statusBar.layer?.backgroundColor, AppAppearance.panel.cgColor)
            XCTAssertTrue(editor.pdfView.document === document)
            XCTAssertEqual(annotation.color, markupColor)
            XCTAssertEqual(editor.pdfView.backgroundColor, canvasColor)
            XCTAssertEqual(editor.view.appearance, rootAppearance)
            XCTAssertNil(editor.pdfView.appearance)
        }
        InterfaceTheme.select(.system)
        XCTAssertNil(editor.markupsPanel.appearance)
        XCTAssertNil(editor.statusBar.appearance)
        XCTAssertEqual(editor.view.appearance, rootAppearance)
        XCTAssertEqual(annotation.color, markupColor)
        XCTAssertEqual(editor.pdfView.backgroundColor, canvasColor)
    }

    func testSettingsControlsPersistAuthorPerformanceAndShortcutEdits() throws {
        _ = NSApplication.shared
        let keys = [MarkupAuthorPreference.defaultsKey, "DrawbridgeShortcutBindings", MainViewController.defaultsIndexCapKey, MainViewController.defaultsAdaptiveIndexCapEnabledKey, MainViewController.defaultsWatchdogEnabledKey, MainViewController.defaultsWatchdogThresholdSecondsKey]
        let defaults = UserDefaults.standard
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let editor = MainViewController()
        editor.loadShortcutBindings()
        let settings = SettingsWindowController(editor: editor)
        settings.prepare()
        let window = try XCTUnwrap(settings.window)
        defer { window.close() }
        func field(_ id: String) throws -> NSTextField { try XCTUnwrap(descendants(window.contentView!).first { $0.identifier?.rawValue == id } as? NSTextField) }
        func click(_ title: String) throws {
            let button = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title })
            button.performClick(nil)
        }
        try field("markupAuthor").stringValue = "  Settings Test  "
        try click("Save General")
        XCTAssertEqual(defaults.string(forKey: MarkupAuthorPreference.defaultsKey), "Settings Test")
        settings.prepare(section: .shortcuts)
        try field("shortcut.selectTool").stringValue = "X"
        try click("Save Shortcuts")
        XCTAssertEqual(editor.currentShortcutBinding(for: .selectTool).key, "x")
        editor.loadShortcutBindings()
        XCTAssertEqual(editor.currentShortcutBinding(for: .selectTool).key, "x")
        try field("shortcut.selectTool").stringValue = "!!"
        try click("Save Shortcuts")
        XCTAssertEqual(editor.currentShortcutBinding(for: .selectTool).key, "x", "Invalid edits cannot overwrite saved bindings")
        try click("Restore Defaults")
        XCTAssertEqual(editor.currentShortcutBinding(for: .selectTool), ShortcutAction.selectTool.defaultBinding)
        settings.prepare(section: .performance)
        try field("indexCap").stringValue = "-1"
        try field("watchdogThreshold").stringValue = "99"
        try click("Apply Performance")
        XCTAssertEqual(defaults.integer(forKey: MainViewController.defaultsIndexCapKey), editor.minimumIndexedMarkupItems)
        XCTAssertEqual(defaults.double(forKey: MainViewController.defaultsWatchdogThresholdSecondsKey), 30)
    }

    func testCustomPaletteChangesChromeWithoutChangingCanvas() {
        let defaults = UserDefaults.standard
        let key = "DrawbridgeInterfaceTheme"
        let old = defaults.object(forKey: key)
        defer { if let old { defaults.set(old, forKey: key) } else { defaults.removeObject(forKey: key) } }
        let appearance = NSAppearance(named: .aqua)!
        func resolved(_ color: NSColor) -> NSColor {
            var result = color
            appearance.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.deviceRGB)! }
            return result
        }
        defaults.removeObject(forKey: key)
        let native = resolved(AppAppearance.chrome)
        let canvas = resolved(AppAppearance.canvas)
        defaults.set("dracula", forKey: key)
        XCTAssertNotEqual(resolved(AppAppearance.chrome), native)
        XCTAssertEqual(resolved(AppAppearance.canvas), canvas, "Interface palettes must not recolor PDF canvas")
    }
}
