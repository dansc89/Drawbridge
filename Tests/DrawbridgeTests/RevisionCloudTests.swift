import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class RevisionCloudTests: XCTestCase {
    func testDragAndClickCreateEditableScallopedPolygons() throws {
        _ = NSApplication.shared
        let controller = MainViewController()
        controller.loadViewIfNeeded()
        let view = controller.pdfView
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 400), for: .mediaBox)
        document.insert(page, at: 0)
        view.setMarkupDocument(document)
        let markup = view.rectangleMarkup
        markup.canEdit = { true }
        func location(_ x: CGFloat, _ y: CGFloat) -> CGPoint { view.convert(CGPoint(x: x, y: y), from: page) }

        markup.tool = .cloud
        XCTAssertTrue(markup.pointerDown(at: location(80, 90)))
        XCTAssertTrue(markup.pointerDragged(at: location(200, 170), modifiers: .shift))
        XCTAssertTrue(markup.pointerUp(at: location(200, 170), modifiers: .shift))
        let box = try XCTUnwrap(markup.selected)
        let record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: box, pageIndex: 0))
        XCTAssertEqual(record.revisionCloud, true)
        XCTAssertEqual(record.kind, .polygon)
        XCTAssertEqual(record.bounds.width, record.bounds.height, accuracy: 0.01)
        XCTAssertNil(record.fill)
        XCTAssertTrue(RevisionCloud.pdfPath(record.vertices).contains(" c "))
        let copy = try record.clipboardAnnotation(contents: box.contents)
        XCTAssertTrue(RectangleMarkupRecord.isCloud(copy))

        markup.tool = .cloud
        for (x, y) in [(80.0, 90.0), (200.0, 90.0), (230.0, 210.0)] {
            XCTAssertTrue(markup.pointerDown(at: location(x, y)))
            XCTAssertTrue(markup.pointerUp(at: location(x, y)))
        }
        XCTAssertTrue(markup.removeLastDraftPoint())
        XCTAssertTrue(markup.pointerDown(at: location(150, 190), clickCount: 2))
        let polygon = try XCTUnwrap(markup.selected)
        XCTAssertTrue(RectangleMarkupRecord.isCloud(polygon))
        XCTAssertEqual(RectangleMarkupRecord.vertices(polygon).count, 3)
    }

    func testScallopsExtendOutwardForBothVertexOrders() {
        let rect = CGRect(x: 50, y: 70, width: 96, height: 80)
        let corners = RevisionCloud.corners(rect)
        for vertices in [corners, Array(corners.reversed())] {
            let outline = RevisionCloud.path(vertices)
            XCTAssertLessThan(outline.boundingBoxOfPath.minX, rect.minX)
            XCTAssertGreaterThan(outline.boundingBoxOfPath.maxY, rect.maxY)
            XCTAssertTrue(outline.contains(CGPoint(x: rect.midX, y: rect.midY)))
        }
    }
}
