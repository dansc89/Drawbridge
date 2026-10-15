import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor private final class InvertShortcutWindow: NSWindow {
    var routesAsKeyWindow = true
    override var isKeyWindow: Bool { routesAsKeyWindow }
}

@MainActor final class InvertShortcutTests: XCTestCase {
    private func isolated(_ body: (MainViewController) throws -> Void) rethrows {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: "DrawbridgeShortcutBindings")
        let menu = NSApp.mainMenu
        defer {
            NSApp.mainMenu = menu
            if let old { defaults.set(old, forKey: "DrawbridgeShortcutBindings") }
            else { defaults.removeObject(forKey: "DrawbridgeShortcutBindings") }
        }
        defaults.removeObject(forKey: "DrawbridgeShortcutBindings")
        let controller = MainViewController()
        _ = controller.view
        controller.loadShortcutBindings()
        try body(controller)
    }

    private func event(_ window: NSWindow, _ flags: NSEvent.ModifierFlags = .control, key: String = "3", repeatKey: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: repeatKey, keyCode: 20))
    }

    private func items(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    func testDefaultMenuAndSettingsUseControlThreeWithoutConflict() throws {
        try isolated { c in
            let action = try XCTUnwrap(ShortcutAction(rawValue: "invert"))
            let binding = c.currentShortcutBinding(for: action)
            XCTAssertEqual(binding.encoded, "control:3")
            XCTAssertEqual(c.shortcutDisplayString(for: action), "Ctrl+3")
            XCTAssertEqual(c.defaultShortcutBindings().values.filter { $0 == binding }.count, 1)
            let delegate = AppDelegate()
            delegate.setupMainMenu(controller: c)
            let menu = try XCTUnwrap(NSApp.mainMenu)
            let invert = try XCTUnwrap(items(menu).first { $0.action == #selector(MainViewController.commandToggleInvert(_:)) })
            XCTAssertEqual(invert.keyEquivalent, "3")
            XCTAssertEqual(invert.keyEquivalentModifierMask, [.control])
            XCTAssertTrue(invert.target === c)
            XCTAssertEqual(items(menu).filter { $0.keyEquivalent == "3" && $0.keyEquivalentModifierMask == [.control] }.count, 1)
            let settings = SettingsWindowController(editor: c)
            settings.prepare(section: .shortcuts)
            defer { settings.window?.close() }
            let field = try XCTUnwrap(views(settings.window!.contentView!).first { $0.identifier?.rawValue == "shortcut.invert" } as? NSTextField)
            XCTAssertEqual(field.stringValue, "3")
            let row = try XCTUnwrap(field.superview)
            XCTAssertEqual(row.subviews.compactMap { $0 as? NSPopUpButton }.first?.titleOfSelectedItem, "Ctrl")
        }
    }

    func testRouterTogglesOnceAcrossCanvasAndSidebarWithKeyboardStateFlags() throws {
        try isolated { c in
            let window = InvertShortcutWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = c
            defer { window.close() }
            let document = PDFDocument(); document.insert(PDFPage(), at: 0)
            c.pdfView.document = document
            for responder in [c.pdfView, c.pagesTableView, c.bookmarksOutlineView] as [NSResponder] {
                XCTAssertTrue(window.makeFirstResponder(responder))
                XCTAssertNil(c.routeKeyDownEvent(try event(window, [.control, .capsLock, NSEvent.ModifierFlags(rawValue: 1)])))
                XCTAssertTrue(c.pdfView.isColorInverted)
                XCTAssertNil(c.routeKeyDownEvent(try event(window, repeatKey: true)))
                XCTAssertTrue(c.pdfView.isColorInverted, "Holding the key must not flicker inversion")
                XCTAssertNil(c.routeKeyDownEvent(try event(window)))
                XCTAssertFalse(c.pdfView.isColorInverted)
                XCTAssertNil(c.secondaryPDFView)
            }
        }
    }

    func testRouterPassesThroughOtherModifiersTextForeignWindowAndNoDocument() throws {
        try isolated { c in
            let window = InvertShortcutWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentViewController = c
            defer { window.close() }
            let noDocument = try event(window)
            XCTAssertTrue(c.routeKeyDownEvent(noDocument) === noDocument)
            let document = PDFDocument(); document.insert(PDFPage(), at: 0); c.pdfView.document = document
            for flags: NSEvent.ModifierFlags in [[], .command, [.control, .shift], [.control, .option], [.control, .command]] {
                let e = try event(window, flags)
                XCTAssertTrue(c.routeKeyDownEvent(e) === e)
                XCTAssertFalse(c.pdfView.isColorInverted)
            }
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30)); c.view.addSubview(text)
            XCTAssertTrue(window.makeFirstResponder(text))
            let editing = try event(window); XCTAssertTrue(c.routeKeyDownEvent(editing) === editing)
            window.routesAsKeyWindow = false
            let foreign = try event(window); XCTAssertTrue(c.routeKeyDownEvent(foreign) === foreign)
            XCTAssertFalse(c.pdfView.isColorInverted)
        }
    }

    func testMenuFallbackRespectsTextFocusAndRemappedControlBindingsRoute() throws {
        try isolated { c in
            let action = try XCTUnwrap(ShortcutAction(rawValue: "invert"))
            let control = try XCTUnwrap(ShortcutModifier(rawValue: "control"))
            let window = InvertShortcutWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentViewController = c
            defer { window.close() }
            let document = PDFDocument(); document.insert(PDFPage(), at: 0); c.pdfView.document = document
            let delegate = AppDelegate(); delegate.setupMainMenu(controller: c)
            let invert = try XCTUnwrap(items(NSApp.mainMenu!).first { $0.action == #selector(MainViewController.commandToggleInvert(_:)) })
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30)); c.view.addSubview(text)
            XCTAssertTrue(window.makeFirstResponder(text))
            XCTAssertFalse(c.validateMenuItem(invert), "A forwarded text-editing key must not toggle through the menu equivalent")
            XCTAssertTrue(window.makeFirstResponder(c.pdfView))
            XCTAssertTrue(c.validateMenuItem(invert))
            c.shortcutBindings[action] = ShortcutBinding(key: "4", modifier: control)
            let oldKey = try event(window)
            XCTAssertTrue(c.routeKeyDownEvent(oldKey) === oldKey)
            XCTAssertNil(c.routeKeyDownEvent(try event(window, key: "4")))
            XCTAssertTrue(c.pdfView.isColorInverted)
            c.shortcutBindings[.selectTool] = ShortcutBinding(key: "x", modifier: control)
            c.setTool(.rectangle)
            XCTAssertNil(c.routeKeyDownEvent(try event(window, key: "x")))
            XCTAssertEqual(c.pdfView.toolMode, .select, "Every modifier offered by Settings must route for Select Text too")
        }
    }

    func testSettingsSavePersistenceAndResetPreserveExistingOverrides() throws {
        try isolated { c in
            UserDefaults.standard.set(["selectTool": "shift:x"], forKey: "DrawbridgeShortcutBindings")
            c.loadShortcutBindings()
            XCTAssertEqual(c.currentShortcutBinding(for: .selectTool).encoded, "shift:x")
            let action = try XCTUnwrap(ShortcutAction(rawValue: "invert"))
            XCTAssertEqual(c.currentShortcutBinding(for: action).encoded, "control:3")
            let delegate = AppDelegate(); delegate.setupMainMenu(controller: c)
            let invert = try XCTUnwrap(items(NSApp.mainMenu!).first { $0.action == #selector(MainViewController.commandToggleInvert(_:)) })
            let settings = SettingsWindowController(editor: c); settings.prepare(section: .shortcuts)
            defer { settings.window?.close() }
            let all = views(settings.window!.contentView!)
            let field = try XCTUnwrap(all.first { $0.identifier?.rawValue == "shortcut.invert" } as? NSTextField)
            field.stringValue = "4"
            try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "Save Shortcuts" }).performClick(nil)
            c.loadShortcutBindings()
            XCTAssertEqual(c.currentShortcutBinding(for: action).encoded, "control:4")
            XCTAssertEqual(c.currentShortcutBinding(for: .selectTool).encoded, "shift:x")
            XCTAssertEqual(invert.keyEquivalent, "4")
            XCTAssertEqual(invert.keyEquivalentModifierMask, [.control])
            try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "Restore Defaults" }).performClick(nil)
            c.loadShortcutBindings()
            XCTAssertEqual(c.currentShortcutBinding(for: action).encoded, "control:3")
            XCTAssertEqual(field.stringValue, "3")
            XCTAssertEqual(invert.keyEquivalent, "3")
        }
    }
}
