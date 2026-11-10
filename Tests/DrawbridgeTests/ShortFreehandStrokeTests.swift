import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class ShortFreehandStrokeTests: XCTestCase {
    private func canvas(_ body: (MarkupPDFView, PDFPage) throws -> Void) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = MarkupPDFView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        let document = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 320, height: 320), for: .mediaBox)
        document.insert(page, at: 0)
        view.setMarkupDocument(document)
        view.displayMode = .singlePage; view.autoScales = false
        view.maxScaleFactor = 40; view.scaleFactor = 22.75; view.go(to: page)
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
        view.rectangleMarkup.canEdit = { true }
        view.rectangleMarkup.undo.groupsByEvent = false
        defer { view.setMarkupDocument(nil); window.close() }
        XCTAssertEqual(view.scaleFactor, 22.75, accuracy: 0.0001)
        try body(view, page)
        XCTAssertFalse(window.isVisible)
    }

    private func stroke(_ view: MarkupPDFView, _ page: PDFPage, points: [CGPoint]) {
        let c = view.rectangleMarkup
        XCTAssertTrue(view.page(for: view.convert(points[0], from: page), nearest: false) === page)
        XCTAssertTrue(c.pointerDown(at: view.convert(points[0], from: page)))
        for point in points.dropFirst() { XCTAssertTrue(c.pointerDragged(at: view.convert(point, from: page))) }
        c.undo.beginUndoGrouping()
        XCTAssertTrue(c.pointerUp(at: view.convert(points.last!, from: page)))
        c.undo.endUndoGrouping()
    }

    private func acceptedStroke(dense: Bool) throws {
        for tool: RectangleMarkupController.Tool in [.pen, .highlight] {
            try canvas { view, page in
                let c = view.rectangleMarkup
                c.tool = tool; c.lineWidth = 1
                let points = dense ? (0...400).map { CGPoint(x: 150 + Double($0) * 0.05, y: 160) } : [CGPoint(x: 150, y: 160), CGPoint(x: 150.5, y: 160)]
                for _ in 0..<2 {
                    let count = page.annotations.count
                    stroke(view, page, points: points)
                    XCTAssertEqual(page.annotations.count, count + 1, "Visible freehand must survive release at 2275%, tool \(tool)")
                    guard let annotation = page.annotations.last else { continue }
                    XCTAssertEqual(RectangleMarkupRecord.vertices(annotation).count, points.count)
                    XCTAssertEqual(c.tool, tool); XCTAssertNil(c.selected); XCTAssertTrue(c.selectedItems.isEmpty)
                    XCTAssertTrue(try XCTUnwrap(RectangleMarkupRecord.capture(annotation: annotation, pageIndex: 0)).isValid)
                    c.undo.undo(); XCTAssertEqual(page.annotations.count, count)
                    c.undo.redo(); XCTAssertTrue(page.annotations.last === annotation)
                    c.setSelectedItems([annotation]) // The following stroke must clear an older selection too.
                }
                c.escape(); XCTAssertEqual(c.tool, .select)
            }
        }
    }

    func testShortPenAndHighlighterSurviveReleaseAt2275Percent() throws { try acceptedStroke(dense: false) }
    func testDenselySampledLongPenAndHighlighterSurviveReleaseAt2275Percent() throws { try acceptedStroke(dense: true) }

    func testClicksAndSubScreenPointJitterDoNotCreateInk() throws {
        for tool: RectangleMarkupController.Tool in [.pen, .highlight] {
            try canvas { view, page in
                let c = view.rectangleMarkup; c.tool = tool
                for dx in [0.0, 0.02] {
                    stroke(view, page, points: [CGPoint(x: 150, y: 160), CGPoint(x: 150 + dx, y: 160)])
                    XCTAssertTrue(page.annotations.isEmpty)
                    XCTAssertFalse(c.hasUnsavedChanges); XCTAssertEqual(c.tool, tool)
                    XCTAssertNil(c.selected); XCTAssertTrue(c.selectedItems.isEmpty)
                }
            }
        }
    }

    func testExplicitPolylineAndPolygonMinimumSegmentsRemainUnchanged() throws {
        try canvas { view, page in
            let c = view.rectangleMarkup
            c.tool = .polyline
            XCTAssertNil(c.createPolyline(on: page, points: [CGPoint(x: 150, y: 160), CGPoint(x: 150.5, y: 160)]))
            c.tool = .polygon
            XCTAssertNil(c.createPolyline(on: page, points: [CGPoint(x: 150, y: 160), CGPoint(x: 150.5, y: 160), CGPoint(x: 150.5, y: 160.5)], closed: true))
            XCTAssertTrue(page.annotations.isEmpty)
        }
    }

    func testShortFreehandRealWriterRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for tool: RectangleMarkupController.Tool in [.pen, .highlight] {
            try canvas { view, page in
                let source = root.appendingPathComponent("source.pdf"), output = root.appendingPathComponent("saved.pdf")
                let document = try XCTUnwrap(view.document)
                XCTAssertTrue(document.write(to: source))
                let original = try Data(contentsOf: source)
                let c = view.rectangleMarkup; c.tool = tool; c.lineWidth = 1
                stroke(view, page, points: [CGPoint(x: 150, y: 160), CGPoint(x: 150.5, y: 160)])
                let annotation = try XCTUnwrap(page.annotations.last)
                let record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: annotation, pageIndex: 0))
                XCTAssertTrue(record.isValid)
                var failure: PDFRectangleWriter.SaveFailure?
                XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: [record], onFailure: { failure = $0 }), "\(failure?.stage ?? "unknown")")
                let reopened = try XCTUnwrap(PDFDocument(url: output))
                let saved = try XCTUnwrap(RectangleMarkupRecord.capture(reopened).first { $0.id == record.id })
                XCTAssertEqual(saved.inkTool, record.inkTool)
                XCTAssertEqual(saved.vertices, record.vertices)
                XCTAssertTrue(saved.isValid)
                XCTAssertEqual(try Data(contentsOf: source), original)
            }
        }
    }
}
