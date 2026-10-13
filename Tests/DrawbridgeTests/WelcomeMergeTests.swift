import AppKit
import XCTest
@testable import Drawbridge

final class WelcomeMergeTests: XCTestCase {
    @MainActor private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @MainActor func testWelcomeButtonUsesMenuWorkflowWithoutDocumentAndCancelsWithoutDuplicates() throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        // Exercise independently constructed controllers, with wiring both before
        // and after loading the view (without launching the application delegate).
        for loadBeforeWiring in [false, true] {
            let delegate = AppDelegate()
            let controller = MainViewController()
            if loadBeforeWiring { _ = controller.view }
            delegate.setupMainMenu(controller: controller)
            let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            parent.contentViewController = controller
            defer {
                if let sheet = parent.attachedSheet { parent.endSheet(sheet); sheet.orderOut(nil) }
                parent.orderOut(nil)
            }
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertNil(controller.pdfView.document)
            XCTAssertNil(controller.openDocumentURL)
            let button = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Merge PDFs…" }, "Welcome card must offer Merge PDFs… alongside Open Existing PDF and Open Recent")
            let fileMenu = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu)
            let menuItem = try XCTUnwrap(fileMenu.items.first { $0.title == "Merge PDFs…" })
            let workflow = try XCTUnwrap(menuItem.target as? PDFMergeWorkflow)
            XCTAssertTrue(button.target === workflow, "Both entry points must reuse the AppDelegate-retained workflow")
            XCTAssertEqual(button.action, menuItem.action)
            XCTAssertTrue(button.isEnabled)
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)

            let row = try XCTUnwrap(button.superview as? NSStackView)
            XCTAssertEqual(row.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }, ["Open Existing PDF", "Open Recent", "Merge PDFs…"])
            let card = try XCTUnwrap(row.superview?.superview)
            for size in [NSSize(width: 1360, height: 700), NSSize(width: 1600, height: 1000)] {
                parent.setContentSize(size)
                controller.view.layoutSubtreeIfNeeded()
                let buttons = row.arrangedSubviews.compactMap { $0 as? NSButton }
                for control in buttons {
                    XCTAssertGreaterThanOrEqual(control.frame.width, control.intrinsicContentSize.width - 1, "Button label must not be clipped")
                    XCTAssertTrue(card.bounds.contains(control.convert(control.bounds, to: card)), "Welcome actions must fit inside the card")
                }
                for (left, right) in zip(buttons, buttons.dropFirst()) {
                    XCTAssertLessThanOrEqual(left.frame.maxX, right.frame.minX, "Welcome actions must not overlap")
                }
            }

            button.performClick(nil)
            let sheet = try XCTUnwrap(parent.attachedSheet, "Actual welcome activation must present the merge sheet with no PDF open")
            XCTAssertEqual(sheet.title, "Merge PDFs")
            button.performClick(nil)
            XCTAssertTrue(parent.attachedSheet === sheet)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(menuItem.action), to: menuItem.target, from: menuItem))
            XCTAssertTrue(parent.attachedSheet === sheet, "File menu must reuse the welcome sheet, not create another workflow")
            XCTAssertEqual(parent.sheets.count, 1)
            let cancel = try XCTUnwrap(descendants(of: try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" })
            cancel.performClick(nil)
            XCTAssertNil(parent.attachedSheet)
            XCTAssertNil(controller.pdfView.document)
            XCTAssertNil(controller.openDocumentURL)

            // Menu-first activation after cancel must also be shared by welcome.
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(menuItem.action), to: menuItem.target, from: menuItem))
            let reopened = try XCTUnwrap(parent.attachedSheet)
            XCTAssertFalse(reopened === sheet)
            button.performClick(nil)
            XCTAssertTrue(parent.attachedSheet === reopened)
            let secondCancel = try XCTUnwrap(descendants(of: try XCTUnwrap(reopened.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" })
            secondCancel.performClick(nil)
            XCTAssertNil(parent.attachedSheet)
            // Rebuilding the menu must retain exactly the same shared target.
            delegate.setupMainMenu(controller: controller)
            let rebuilt = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu?.items.first { $0.title == "Merge PDFs…" })
            XCTAssertTrue(rebuilt.target === workflow)
            XCTAssertTrue(button.target === workflow)
        }
    }
}
