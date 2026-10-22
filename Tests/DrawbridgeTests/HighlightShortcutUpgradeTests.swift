import AppKit
import XCTest
@testable import Drawbridge

@MainActor final class HighlightShortcutUpgradeTests: XCTestCase {
    private let defaultsKey = "DrawbridgeShortcutBindings"

    private func isolated(_ body: (MainViewController) throws -> Void) rethrows {
        _ = NSApplication.shared
        let previous = UserDefaults.standard.object(forKey: defaultsKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let controller = MainViewController()
        _ = controller.view
        try body(controller)
    }

    private func event(_ binding: ShortcutBinding) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: binding.menuModifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: binding.key, charactersIgnoringModifiers: binding.key,
            isARepeat: false, keyCode: 4))
    }

    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    func testEveryLegacyPlainHOverrideSurvivesWithReachableShiftHighlight() throws {
        try isolated { controller in
            for legacy in [ShortcutAction.selectTool, .invert, .hyperlinks] {
                let raw = [legacy.rawValue: "plain:h"]
                UserDefaults.standard.set(raw, forKey: defaultsKey)
                controller.loadShortcutBindings()
                let highlight = ShortcutBinding(key: "h", modifier: .shift)
                XCTAssertEqual(controller.currentShortcutBinding(for: legacy).encoded, "plain:h")
                XCTAssertEqual(controller.currentShortcutBinding(for: .highlight), highlight)
                XCTAssertEqual(controller.shortcutAction(for: try event(highlight)), .highlight)
                XCTAssertEqual(controller.shortcutAction(for: try event(.init(key: "h", modifier: .plain))), legacy)
                let loaded = controller.shortcutBindings
                controller.loadShortcutBindings()
                XCTAssertEqual(controller.shortcutBindings, loaded, "Loading the same legacy preferences must be deterministic")
                XCTAssertEqual(UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String], raw,
                    "Loading must not overwrite the user's saved preferences")
                controller.saveShortcutBindings()
                controller.loadShortcutBindings()
                XCTAssertEqual(controller.shortcutBindings, loaded)
            }
        }
    }

    func testFallbackSkipsOccupiedModifiedHsRegardlessOfPreferenceInsertionOrder() throws {
        try isolated { controller in
            let entries = [("selectTool", "plain:h"), ("invert", "shift:h"), ("hyperlinks", "commandShift:h")]
            for ordered in [entries, Array(entries.reversed())] {
                let raw = Dictionary(uniqueKeysWithValues: ordered)
                UserDefaults.standard.set(raw, forKey: defaultsKey)
                controller.loadShortcutBindings()
                let fallback = ShortcutBinding(key: "h", modifier: .control)
                XCTAssertEqual(controller.currentShortcutBinding(for: .highlight), fallback)
                XCTAssertEqual(controller.shortcutAction(for: try event(fallback)), .highlight)
                for (name, encoded) in entries {
                    XCTAssertEqual(controller.currentShortcutBinding(for: try XCTUnwrap(ShortcutAction(rawValue: name))).encoded, encoded)
                }
                let loaded = controller.shortcutBindings
                controller.saveShortcutBindings()
                controller.loadShortcutBindings()
                XCTAssertEqual(controller.shortcutBindings, loaded)
            }
        }
    }

    func testUnoccupiedDefaultAndExplicitHighlightCustomizationRemainUnchanged() throws {
        try isolated { controller in
            for raw in [[String: String](), ["invert": "plain:h", "highlight": "shift:j"],
                        ["invert": "plain:h", "highlight": "shift:h"]] {
                UserDefaults.standard.set(raw, forKey: defaultsKey)
                controller.loadShortcutBindings()
                XCTAssertEqual(controller.currentShortcutBinding(for: .highlight).encoded, raw["highlight"] ?? "plain:h")
            }
        }
    }

    func testMigratedSettingsSaveRemapAndReloadUpdateDisplayedBinding() throws {
        try isolated { controller in
            UserDefaults.standard.set(["invert": "plain:h"], forKey: defaultsKey)
            controller.loadShortcutBindings()
            controller.updateShortcutHintLabel()
            XCTAssertEqual(controller.rectangleToolbar.highlightButton.toolTip, "Highlight (Shift+H)")
            let settings = SettingsWindowController(editor: controller)
            settings.prepare(section: .shortcuts)
            defer { settings.window?.close() }
            let all = views(try XCTUnwrap(settings.window?.contentView))
            let field = try XCTUnwrap(all.first { $0.identifier?.rawValue == "shortcut.highlight" } as? NSTextField)
            XCTAssertEqual(field.stringValue, "H")
            let popup = try XCTUnwrap(field.superview?.subviews.compactMap { $0 as? NSPopUpButton }.first)
            XCTAssertEqual(popup.titleOfSelectedItem, "Shift")
            XCTAssertTrue(all.compactMap { $0 as? NSTextField }.contains {
                $0.stringValue.hasPrefix("Customize ") && $0.stringValue.contains("Highlight")
            })
            let save = try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "Save Shortcuts" })
            save.performClick(nil)
            XCTAssertTrue(all.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Shortcuts saved." })
            controller.loadShortcutBindings()
            XCTAssertEqual(controller.currentShortcutBinding(for: .highlight).encoded, "shift:h")
            field.stringValue = "J"
            save.performClick(nil)
            controller.loadShortcutBindings()
            XCTAssertEqual(controller.currentShortcutBinding(for: .invert).encoded, "plain:h")
            XCTAssertEqual(controller.currentShortcutBinding(for: .highlight).encoded, "shift:j")
            XCTAssertEqual(controller.rectangleToolbar.highlightButton.toolTip, "Highlight (Shift+J)")
            XCTAssertNil(controller.shortcutAction(for: try event(.init(key: "h", modifier: .shift))))
            XCTAssertEqual(controller.shortcutAction(for: try event(.init(key: "j", modifier: .shift))), .highlight)
        }
    }
}
