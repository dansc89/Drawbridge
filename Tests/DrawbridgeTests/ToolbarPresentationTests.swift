import AppKit
import XCTest
@testable import Drawbridge

@MainActor
final class ToolbarPresentationTests: XCTestCase {
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
        XCTAssertEqual(buttons.count, 4)
        XCTAssertEqual(buttons.map(\.action), [#selector(MainViewController.openPDF), #selector(MainViewController.commandAutoGenerateSheetNames(_:)), #selector(MainViewController.commandBatchLinkSheetNumbers(_:)), #selector(MainViewController.commandFlattenPDF(_:))])
        XCTAssertTrue(buttons.allSatisfy { $0.target === controller && !$0.isHidden && $0.image != nil })
        XCTAssertTrue(controller.responds(to: #selector(MainViewController.toolbarAllowedItemIdentifiers(_:))))
        XCTAssertTrue(controller.responds(to: #selector(MainViewController.outlineViewSelectionDidChange(_:))))
        XCTAssertTrue(controller.responds(to: #selector(MainViewController.splitViewDidResizeSubviews(_:))))
    }
}
