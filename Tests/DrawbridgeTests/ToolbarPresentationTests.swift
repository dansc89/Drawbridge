import AppKit
import XCTest
@testable import Drawbridge

@MainActor
final class ToolbarPresentationTests: XCTestCase {
    func testMarkupPropertyMenusKeepTheirChoicesEnabled() {
        _ = NSApplication.shared
        let toolbar = RectangleMarkupToolbar(frame:.zero)
        for popup in [toolbar.colorPopup,toolbar.widthPopup,toolbar.fontPopup] {
            XCTAssertFalse(popup.menu?.autoenablesItems ?? true)
            XCTAssertTrue(popup.itemArray.allSatisfy(\.isEnabled))
        }
    }

    func testBusyCancellationRemainsClickableWhileDocumentIsLocked() {
        _ = NSApplication.shared
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.beginBusyIndicator("Testing")
        XCTAssertTrue(window.ignoresMouseEvents)
        controller.setBusyCancelAction({})
        XCTAssertFalse(window.ignoresMouseEvents)
        controller.setBusyCancelAction(nil)
        XCTAssertTrue(window.ignoresMouseEvents)
        controller.endBusyIndicator()
        XCTAssertFalse(window.ignoresMouseEvents)
    }

    func testPageNavigationButtonsAreSeparateFromHistoryAndDisabledWithoutDocument() throws {
        _ = NSApplication.shared
        let controller = MainViewController()
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1400,height:900),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentViewController = controller; window.layoutIfNeeded()
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let all = buttons(controller.view)
        let previous = try XCTUnwrap(all.first { $0.identifier?.rawValue == "drawbridgePreviousPage" })
        let next = try XCTUnwrap(all.first { $0.identifier?.rawValue == "drawbridgeNextPage" })
        let back = try XCTUnwrap(all.first { $0.identifier?.rawValue == "drawbridgeNavigateBack" })
        XCTAssertEqual(previous.action,#selector(MainViewController.commandPreviousPage(_:)))
        XCTAssertEqual(next.action,#selector(MainViewController.commandNextPage(_:)))
        XCTAssertEqual(back.action,#selector(MainViewController.commandNavigateBack(_:)))
        XCTAssertFalse(previous.isEnabled); XCTAssertFalse(next.isEnabled)
        XCTAssertNotNil(previous.image); XCTAssertNotNil(next.image)
        XCTAssertFalse(previous.superview === back.superview)
    }

    func testAppKitInstallsPrimaryCommandButtons() throws {
        _ = NSApplication.shared
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.toolbar = controller.makeToolbar()
        window.layoutIfNeeded()
        let toolbar = try XCTUnwrap(window.toolbar)
        let primary = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == .drawbridgePrimaryControls }, "AppKit must install the commands, not just return their identifiers")
        XCTAssertTrue(toolbar.visibleItems?.contains { $0.itemIdentifier == .drawbridgePrimaryControls } == true)
        let stack = try XCTUnwrap(primary.view as? NSStackView)
        XCTAssertNotNil(stack.superview)
        XCTAssertGreaterThan(stack.frame.width, 0)
        let buttons = stack.arrangedSubviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 7)
        XCTAssertEqual(buttons.map(\.action), [#selector(MainViewController.openPDF), #selector(MainViewController.commandAutoGenerateSheetNames(_:)), #selector(MainViewController.commandBatchLinkSheetNumbers(_:)), #selector(MainViewController.commandFlattenPDF(_:)), #selector(MainViewController.commandReduceFileSize(_:)), #selector(MainViewController.commandGoToSheet(_:)), #selector(MainViewController.commandFitPage(_:))])
        XCTAssertTrue(buttons.allSatisfy { $0.target === controller && !$0.isHidden && $0.image != nil })
        XCTAssertEqual(buttons[4].image?.name(), NSImage.Name("DrawbridgeCompressionClamp"))
        XCTAssertTrue(buttons[4].image?.isTemplate == true)
        XCTAssertTrue(controller.responds(to: #selector(MainViewController.toolbarAllowedItemIdentifiers(_:))))
        XCTAssertTrue(controller.responds(to: #selector(MainViewController.outlineViewSelectionDidChange(_:))))
        XCTAssertTrue(controller.responds(to: #selector(MainViewController.splitViewDidResizeSubviews(_:))))
    }
}
