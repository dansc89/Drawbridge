import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class MarkupInteractionTests: XCTestCase {
    private func setup() -> (MainViewController, PDFPage) {
        _ = NSApplication.shared
        let controller = MainViewController(); controller.loadViewIfNeeded()
        let document = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 400), for: .mediaBox)
        document.insert(page, at: 0); controller.pdfView.setMarkupDocument(document)
        controller.pdfView.rectangleMarkup.canEdit = { true }
        return (controller, page)
    }

    func testScaleControlFollowsMarkupsInStatusBar() throws {
        let (controller, _) = setup()
        let scale = controller.rectangleToolbar.scaleButton
        XCTAssertFalse(controller.rectangleToolbar.arrangedSubviews.contains { $0 === scale })
        let stack = try XCTUnwrap(controller.markupsToggleButton.superview as? NSStackView)
        let index = try XCTUnwrap(stack.arrangedSubviews.firstIndex { $0 === controller.markupsToggleButton })
        XCTAssertTrue(stack.arrangedSubviews.count > index + 1)
        if stack.arrangedSubviews.count > index + 1 { XCTAssertTrue(stack.arrangedSubviews[index + 1] === scale) }
        XCTAssertTrue(scale.target === controller)
        XCTAssertEqual(scale.action, #selector(MainViewController.commandSetPageDrawingScale(_:)))
        controller.refreshRectangleToolbar(); XCTAssertTrue(scale.isEnabled)
        controller.pdfView.rectangleMarkup.canEdit = { false }
        controller.refreshRectangleToolbar(); XCTAssertFalse(scale.isEnabled)
    }

    func testSuccessfulCreationSelectsNewMarkupAndUpdatesToolbar() throws {
        let (controller, page) = setup(), session = controller.pdfView.rectangleMarkup
        for tool in [RectangleMarkupController.Tool.rectangle, .ellipse, .text, .polygon, .polyline, .arrow] {
            session.tool = tool
            let annotation = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 20, y: 20, width: 60, height: 60)))
            XCTAssertEqual(session.tool, .select)
            XCTAssertTrue(session.selected === annotation)
            XCTAssertEqual(controller.rectangleToolbar.selectButton.state, .on)
            XCTAssertTrue(controller.rectangleToolbar.deleteButton.isEnabled)
        }
    }

    func testSnapshotPlacementSelectsCaptureAndAdjacentOrderKeepsTilesWithOwner() throws {
        let (controller, page) = setup(), session = controller.pdfView.rectangleMarkup
        let payload = SnapshotPayload(data: try XCTUnwrap(controller.pdfView.document?.dataRepresentation()))
        session.tool = .snapshotBox
        let capture = try XCTUnwrap(session.pasteSnapshot(payload, on: page, center: CGPoint(x: 300, y: 200)) as? DrawbridgeSnapshotAnnotation)
        XCTAssertEqual(session.tool, .select); XCTAssertTrue(session.selected === capture)
        let other = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 30, y: 30, width: 40, height: 40)))
        // Isolate logical order from viewport rendering, which disposes synthetic tiles.
        session.view = nil
        let tile = SnapshotViewportTileAnnotation(snapshot: capture, bounds: capture.bounds)
        page.removeAnnotation(other); page.addAnnotation(tile); page.addAnnotation(other)
        session.setSelectedItems([capture]); session.undo.groupsByEvent = false
        session.undo.removeAllActions()
        session.undo.beginUndoGrouping(); controller.commandBringMarkupForward(nil); session.undo.endUndoGrouping()
        XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), [other, capture, tile].map(ObjectIdentifier.init))
        session.undo.undo()
        XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), [capture, tile, other].map(ObjectIdentifier.init))
        session.undo.redo()
        XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), [other, capture, tile].map(ObjectIdentifier.init))
    }

    func testContextMenuIncludesAdjacentStackingActions() throws {
        let (controller, page) = setup(), session = controller.pdfView.rectangleMarkup
        _ = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 100, y: 100, width: 60, height: 60)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        controller.pdfView.layoutDocumentView()
        let viewPoint = controller.pdfView.convert(CGPoint(x: 100, y: 130), from: page)
        let location = controller.pdfView.convert(viewPoint, to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(controller.pdfView.menu(for: event))
        XCTAssertTrue(menu.items.contains { $0.title == "Bring Forward" })
        XCTAssertTrue(menu.items.contains { $0.title == "Send Backward" })
    }

    func testTextDraftAndCancellationDoNotFinishPlacement() {
        let (controller, page) = setup(), session = controller.pdfView.rectangleMarkup
        session.tool = .text
        session.beginTextEditing(on: page, bounds: CGRect(x: 20, y: 20, width: 100, height: 40))
        XCTAssertEqual(session.tool, .text); XCTAssertTrue(session.isEditingText)
        session.finishTextEditing(cancel: true)
        XCTAssertEqual(session.tool, .text); XCTAssertTrue(page.annotations.isEmpty)
        session.tool = .polygon; session.cancelGesture()
        XCTAssertEqual(session.tool, .polygon); XCTAssertTrue(page.annotations.isEmpty)
        XCTAssertNil(session.create(on: page, bounds: .zero))
        XCTAssertEqual(session.tool, .polygon)
    }

    func testAdjacentStackingCommandsPreserveSelectionOrderUndoRedoAndEdgeNoOp() throws {
        let (controller, page) = setup(), session = controller.pdfView.rectangleMarkup
        session.undo.groupsByEvent = false; session.undo.beginUndoGrouping()
        let items = try (0..<5).map { i in try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 20 + i * 30, y: 20, width: 20, height: 20))) }
        session.undo.endUndoGrouping(); session.undo.removeAllActions()
        session.setSelectedItems([items[2], items[1]])
        session.undo.beginUndoGrouping(); controller.commandBringMarkupForward(nil); session.undo.endUndoGrouping()
        XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), [items[0], items[3], items[1], items[2], items[4]].map(ObjectIdentifier.init))
        XCTAssertEqual(session.selectedItems.map(ObjectIdentifier.init), [items[2], items[1]].map(ObjectIdentifier.init))
        XCTAssertTrue(session.undo.canUndo)
        if session.undo.canUndo {
            session.undo.undo(); XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), items.map(ObjectIdentifier.init))
            session.undo.redo(); XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), [items[0], items[3], items[1], items[2], items[4]].map(ObjectIdentifier.init))
        }
        session.undo.beginUndoGrouping(); controller.commandSendMarkupBackward(nil); session.undo.endUndoGrouping()
        XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), items.map(ObjectIdentifier.init))
        session.setSelectedItems([items[4]]); session.undo.removeAllActions()
        controller.commandBringMarkupForward(nil)
        XCTAssertFalse(session.undo.canUndo)
        session.setSelectedItems([items[0]])
        controller.commandSendMarkupBackward(nil)
        XCTAssertFalse(session.undo.canUndo)
    }
}
