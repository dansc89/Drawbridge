import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class HighlighterDeselectionTests: XCTestCase {
    func testRepeatedStrokesStayDeselectedAfterDebouncedPublicationAndRemainSelectable() throws {
        _ = NSApplication.shared
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer {
            controller.pdfView.setMarkupDocument(nil)
            window.makeFirstResponder(nil)
            window.contentViewController = nil
            window.close()
        }
        let document = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 320, height: 320), for: .mediaBox)
        document.insert(page, at: 0)
        let view = controller.pdfView, session = view.rectangleMarkup
        view.setMarkupDocument(document)
        view.displayMode = .singlePage; view.autoScales = true; view.go(to: page)
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
        session.canEdit = { true }; session.undo.groupsByEvent = false
        controller.performRefreshMarkups(selecting: nil, forceImmediate: true)
        let overlays = (view.layer?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }.filter { (20...23).contains(Int($0.zPosition)) }
        XCTAssertEqual(overlays.count, 4)
        var publications = 0
        controller.onMarkupListReload = { publications += 1 }
        session.tool = .highlight
        for index in 0..<2 {
            let points = [CGPoint(x: 50, y: 70 + index * 60), CGPoint(x: 100, y: 70 + index * 60), CGPoint(x: 200, y: 100 + index * 60)]
            XCTAssertTrue(session.pointerDown(at: view.convert(points[0], from: page)))
            for point in points.dropFirst() { XCTAssertTrue(session.pointerDragged(at: view.convert(point, from: page))) }
            session.undo.beginUndoGrouping()
            XCTAssertTrue(session.pointerUp(at: view.convert(points.last!, from: page)))
            session.undo.endUndoGrouping()
            let annotation = try XCTUnwrap(page.annotations.last)
            XCTAssertNil(session.selected)
            XCTAssertTrue(session.selectedItems.isEmpty)
            XCTAssertEqual(session.tool, .highlight)
            XCTAssertEqual(controller.markupsTable.selectedRowIndexes, IndexSet(), "Completion clears prior table selection")
            XCTAssertTrue(overlays.allSatisfy { $0.isHidden && $0.path == nil }, "Completion clears visual selection")
            let before = publications
            // Exercise the real 0.45-second mutation debounce, not a direct refresh call.
            RunLoop.current.run(until: Date().addingTimeInterval(0.75))
            XCTAssertGreaterThan(publications, before, "The scheduled list publication must actually execute")
            XCTAssertEqual(controller.markupsTable.numberOfRows, index + 1)
            XCTAssertEqual(controller.markupsTable.selectedRowIndexes, IndexSet(), "Delayed publication must not resurrect the stroke selection")
            XCTAssertTrue(overlays.allSatisfy { $0.isHidden && $0.path == nil }, "No dashed box or endpoint handles after delayed refresh")
            XCTAssertNil(session.selected)
            XCTAssertTrue(session.selectedItems.isEmpty)
            XCTAssertEqual(session.tool, .highlight)
            XCTAssertEqual(controller.rectangleToolbar.highlightButton.state, .on)
            // Explicit later sidebar selection remains functional; the next stroke must clear it.
            let row = try XCTUnwrap(controller.markupItems.firstIndex { $0.annotation === annotation })
            controller.applyMarkupTableSelectionRows(IndexSet(integer: row))
            XCTAssertEqual(controller.markupsTable.selectedRowIndexes, IndexSet(integer: row))
            XCTAssertTrue(overlays.contains { !$0.isHidden && $0.path != nil }, "Completed strokes remain visually selectable")
        }
        XCTAssertFalse(window.isVisible)
    }
}
