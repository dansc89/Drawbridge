import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

// No foreground window or application launch: exercise the real monitor/router and outline.
@MainActor private final class BookmarkArrowWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor
final class BookmarkArrowNavigationTests: XCTestCase {
    private func withBookmarks(_ body: (MainViewController, NSWindow, PDFDocument, [PDFOutline]) throws -> Void) throws {
        _ = NSApplication.shared
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        for _ in 0..<8 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        let root = PDFOutline()
        let bookmarks = try [0, 5, 2].enumerated().map { index, pageIndex in
            let node = PDFOutline()
            node.label = "Bookmark \(index)"
            node.destination = PDFDestination(page: try XCTUnwrap(document.page(at: pageIndex)), at: CGPoint(x: 0, y: 800))
            root.insertChild(node, at: index)
            return node
        }
        document.outlineRoot = root
        let controller = MainViewController()
        let window = BookmarkArrowWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.pdfView.setMarkupDocument(document)
        controller.bookmarksOutlineView.reloadData()
        window.layoutIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(controller.bookmarksOutlineView))
        try body(controller, window, document, bookmarks)
    }

    private func arrow(_ code: UInt16, flags: NSEvent.ModifierFlags = [], controller: MainViewController, window: NSWindow) throws {
        let character: String = code == 125 ? "\u{f701}" : code == 126 ? "\u{f700}" : code == 123 ? "\u{f702}" : "\u{f703}"
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
        if let forwarded = controller.routeKeyDownEvent(event) {
            window.firstResponder?.keyDown(with: forwarded)
        }
    }

    func testUpDownSelectVisibleRowsAndNavigateNonconsecutiveDestinations() throws {
        try withBookmarks { controller, window, document, _ in
            let outline = controller.bookmarksOutlineView
            outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            controller.pdfView.go(to: document.page(at: 0)!)
            for (code, row, page) in [(UInt16(125), 1, 5), (125, 2, 2), (126, 1, 5), (126, 0, 0)] {
                try arrow(code, controller: controller, window: window)
                XCTAssertEqual(outline.selectedRowIndexes, IndexSet(integer: row))
                XCTAssertTrue(controller.pdfView.currentPage === document.page(at: page), "Must follow bookmark destination, not adjacent PDF page")
                XCTAssertTrue(window.firstResponder === outline)
            }
        }
    }

    func testBoundsDoNotPageDocumentOrChangeFocus() throws {
        try withBookmarks { controller, window, document, _ in
            let outline = controller.bookmarksOutlineView
            for (row, page, code) in [(0, 0, UInt16(126)), (2, 2, 125)] {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                controller.pdfView.go(to: document.page(at: page)!)
                try arrow(code, controller: controller, window: window)
                XCTAssertEqual(outline.selectedRow, row)
                XCTAssertTrue(controller.pdfView.currentPage === document.page(at: page))
                XCTAssertTrue(window.firstResponder === outline)
            }
        }
    }

    func testNativeShiftExtendsSelectionWithoutNavigating() throws {
        try withBookmarks { controller, window, document, _ in
            let outline = controller.bookmarksOutlineView
            outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            controller.pdfView.go(to: document.page(at: 0)!)
            try arrow(125, flags: .shift, controller: controller, window: window)
            XCTAssertEqual(outline.selectedRowIndexes, IndexSet([0, 1]))
            XCTAssertTrue(controller.pdfView.currentPage === document.page(at: 0))
            XCTAssertTrue(window.firstResponder === outline)
        }
    }

    func testNativeExpansionAndVisibleHierarchyIncludingDestinationlessGroup() throws {
        try withBookmarks { controller, window, document, bookmarks in
            let outline = controller.bookmarksOutlineView
            let group = bookmarks[1]
            group.destination = nil
            let child = PDFOutline(); child.label = "Child"
            child.destination = PDFDestination(page: document.page(at: 7)!, at: CGPoint(x: 0, y: 800))
            group.insertChild(child, at: 0)
            outline.reloadData(); outline.collapseItem(group)
            outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            controller.pdfView.go(to: document.page(at: 0)!)
            try arrow(124, controller: controller, window: window)
            XCTAssertTrue(outline.isItemExpanded(group))
            XCTAssertTrue(controller.pdfView.currentPage === document.page(at: 0))
            try arrow(125, controller: controller, window: window)
            XCTAssertTrue(outline.item(atRow: outline.selectedRow) as? PDFOutline === child)
            XCTAssertTrue(controller.pdfView.currentPage === document.page(at: 7))
            try arrow(126, controller: controller, window: window)
            XCTAssertTrue(outline.item(atRow: outline.selectedRow) as? PDFOutline === group)
            XCTAssertTrue(controller.pdfView.currentPage === document.page(at: 7), "Destinationless groups must not page")
            try arrow(123, controller: controller, window: window)
            XCTAssertFalse(outline.isItemExpanded(group))
            try arrow(125, controller: controller, window: window)
            XCTAssertTrue(outline.item(atRow: outline.selectedRow) as? PDFOutline === bookmarks[2])
            XCTAssertTrue(controller.pdfView.currentPage === document.page(at: 2))
            XCTAssertTrue(window.firstResponder === outline)
        }
    }

    func testProgrammaticSelectionReloadAndClickActionRetainExistingBehavior() throws {
        try withBookmarks { controller, window, document, _ in
            let outline = controller.bookmarksOutlineView
            controller.pdfView.go(to: document.page(at: 0)!)
            outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            outline.reloadData()
            outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            XCTAssertTrue(controller.pdfView.currentPage === document.page(at: 0))
            XCTAssertTrue(outline.sendAction(outline.action, to: outline.target))
            XCTAssertTrue(controller.pdfView.currentPage === document.page(at: 5))
            XCTAssertTrue(window.firstResponder === outline)
            outline.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
            _ = outline.sendAction(outline.action, to: outline.target)
            XCTAssertTrue(controller.pdfView.currentPage === document.page(at: 5))
            XCTAssertEqual(outline.doubleAction, #selector(MainViewController.renameBookmarkFromSidebar))
        }
    }

    func testCanvasArrowsStillPageAndTextEditingPassesThrough() throws {
        try withBookmarks { controller, window, document, _ in
            XCTAssertTrue(window.makeFirstResponder(controller.pdfView))
            controller.pdfView.go(to: document.page(at: 3)!)
            for (code, page) in [(UInt16(125), 4), (126, 3), (124, 4), (123, 3)] {
                try arrow(code, controller: controller, window: window)
                XCTAssertTrue(controller.pdfView.currentPage === document.page(at: page))
            }
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
            text.string = "Editing\ntext"
            controller.view.addSubview(text)
            XCTAssertTrue(window.makeFirstResponder(text))
            for code: UInt16 in [123, 124, 125, 126] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{f700}", charactersIgnoringModifiers: "\u{f700}", isARepeat: false, keyCode: code))
                XCTAssertTrue(controller.routeKeyDownEvent(event) === event)
                XCTAssertTrue(controller.pdfView.currentPage === document.page(at: 3))
                XCTAssertTrue(window.firstResponder === text)
            }
        }
    }
}
