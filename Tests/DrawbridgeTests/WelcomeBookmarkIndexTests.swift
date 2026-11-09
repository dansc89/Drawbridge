import XCTest
import AppKit
@testable import Drawbridge

@MainActor final class WelcomeBookmarkIndexTests: XCTestCase {
    private let title = "Extract Bookmark Index…"

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func menuItem() throws -> NSMenuItem {
        let file = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu)
        return try XCTUnwrap(file.items.first { $0.title == title })
    }

    private func button(_ controller: MainViewController) throws -> NSButton {
        try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == title },
                      "Welcome must offer Extract Bookmark Index without opening a PDF")
    }

    private func withWelcome(viewFirst: Bool = false, _ body: (AppDelegate, MainViewController, NSWindow) throws -> Void) throws {
        _ = NSApplication.shared
        let savedMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = savedMenu }
        let delegate = AppDelegate(), controller = MainViewController()
        if viewFirst { controller.loadViewIfNeeded() }
        delegate.setupMainMenu(controller: controller)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.orderOut(nil); window.contentViewController = nil }
        controller.view.layoutSubtreeIfNeeded()
        try body(delegate, controller, window)
    }

    func testWelcomeButtonUsesRetainedMenuTargetBeforeAndAfterViewLoading() throws {
        for viewFirst in [false, true] {
            try withWelcome(viewFirst: viewFirst) { delegate, controller, _ in
                let button = try button(controller), item = try menuItem()
                XCTAssertTrue(button.isEnabled)
                XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
                XCTAssertTrue(button.target === item.target)
                XCTAssertEqual(button.action, item.action)
                XCTAssertEqual(button.action, #selector(BookmarkIndexWorkflow.showExtract(_:)))
                let target = try XCTUnwrap(item.target as? BookmarkIndexWorkflow)
                XCTAssertTrue(target.validateMenuItem(item))
                delegate.setupMainMenu(controller: controller)
                XCTAssertTrue(try menuItem().target === target)
                XCTAssertTrue(button.target === target)
                XCTAssertNil(controller.pdfView.document)
            }
        }
    }

    func testPerformClickChoosesFolderWithoutDocumentAndCancelAllowsMenuAndButtonReopen() throws {
        try withWelcome { _, controller, _ in
            let button = try button(controller), item = try menuItem()
            let workflow = try XCTUnwrap(item.target as? BookmarkIndexWorkflow)
            var completions: [(URL?) -> Void] = []
            workflow.chooseFolder = { completions.append($0) }
            workflow.resolveDownloads = { XCTFail("Folder cancellation must not resolve output"); throw CocoaError(.userCancelled) }
            workflow.notify = { _ in XCTFail("Folder cancellation must not present a result") }
            defer { completions.last?(nil); workflow.chooseFolder = nil }
            let recents = NSDocumentController.shared.recentDocumentURLs
            button.performClick(nil)
            XCTAssertEqual(completions.count, 1)
            XCTAssertTrue(workflow.busy)
            button.performClick(nil)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(completions.count, 1, "Both entry points share busy admission")
            completions.last?(nil)
            XCTAssertFalse(workflow.busy)
            XCTAssertTrue(workflow.validateMenuItem(item))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(completions.count, 2)
            button.performClick(nil)
            XCTAssertEqual(completions.count, 2)
            completions.last?(nil)
            button.performClick(nil)
            XCTAssertEqual(completions.count, 3)
            completions.last?(nil)
            XCTAssertFalse(workflow.busy)
            XCTAssertNil(workflow.result)
            XCTAssertNil(controller.pdfView.document)
            XCTAssertEqual(NSDocumentController.shared.recentDocumentURLs, recents)
        }
    }

    func testWelcomeActionsFitCardAndCanvasAtSupportedMinimumWidths() throws {
        try withWelcome { _, controller, window in
            let extract = try button(controller)
            let card = try XCTUnwrap(descendants(controller.view).first { $0 is StartupDropView })
            let titles = ["Open Existing PDF", "Open Recent", "Merge PDFs…", title]
            let buttons = descendants(card).compactMap { $0 as? NSButton }.filter { titles.contains($0.title) }
            XCTAssertEqual(buttons.map(\.title), titles)
            for width: CGFloat in [1360, 1420, 1600] {
                window.setContentSize(NSSize(width: width, height: 700))
                controller.view.layoutSubtreeIfNeeded()
                let canvas = try XCTUnwrap(card.superview)
                XCTAssertTrue(canvas.bounds.insetBy(dx: -1, dy: -1).contains(card.frame), "Card outside canvas at \(width)")
                for button in buttons {
                    let frame = button.convert(button.bounds, to: card)
                    XCTAssertTrue(card.bounds.contains(frame), "\(button.title) clipped at \(width)")
                    XCTAssertGreaterThanOrEqual(button.bounds.width + 0.5, button.intrinsicContentSize.width)
                    XCTAssertGreaterThanOrEqual(button.bounds.height + 0.5, button.intrinsicContentSize.height)
                    for other in buttons where other !== button {
                        XCTAssertFalse(frame.intersects(other.convert(other.bounds, to: card)), "Overlapping welcome actions")
                    }
                }
                XCTAssertFalse(extract.isHiddenOrHasHiddenAncestor)
            }
        }
    }
}
