import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class MarkupPropertiesTests: XCTestCase {
    private func fixture() throws -> URL {
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Properties-\(UUID().uuidString).pdf")
        try (data as Data).write(to: url); return url
    }
    func testCustomPropertiesRoundTripUndoAndDoNotChangeDrawingDefaults() throws {
        let source = try fixture(), output = source.appendingPathExtension("saved.pdf")
        defer { [source,output].forEach { try? FileManager.default.removeItem(at: $0) } }
        let original = try Data(contentsOf: source)
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        let session = RectangleMarkupController(); session.bind(to: document); session.undo.groupsByEvent = false
        session.undo.beginUndoGrouping()
        let annotation = try XCTUnwrap(session.createPolyline(on: page, points: [CGPoint(x: 40,y: 40),CGPoint(x: 200,y: 80),CGPoint(x: 130,y: 180)], closed: true))
        session.undo.endUndoGrouping()
        session.undo.removeAllActions()
        let custom = NSColor(deviceRed: 0.22, green: 0.55, blue: 0.73, alpha: 1)
        session.undo.beginUndoGrouping()
        session.styleSelected(color: custom, width: 3.75)
        session.fillSelected(custom)
        session.undo.endUndoGrouping()
        XCTAssertEqual(session.strokeColor, .red); XCTAssertEqual(session.lineWidth, 2); XCTAssertEqual(session.fillColor, .orange)
        XCTAssertEqual(annotation.border?.lineWidth, 3.75)
        let expected = RectangleMarkupRecord.capture(document)
        session.undo.undo(); XCTAssertEqual(annotation.border?.lineWidth, 2)
        session.undo.redo(); XCTAssertEqual(RectangleMarkupRecord.capture(document), expected)
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: expected))
        XCTAssertEqual(RectangleMarkupRecord.capture(try XCTUnwrap(PDFDocument(url: output))), expected)
        XCTAssertEqual(try Data(contentsOf: output).prefix(original.count), original)
        XCTAssertEqual(page.rotation, 0); XCTAssertEqual(page.bounds(for: .mediaBox), CGRect(x: 0,y: 0,width: 400,height: 300))
    }
    func testInspectorEditsSelectionAndDisplaysCustomValuesWithoutLosingColor() throws {
        _ = NSApplication.shared
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        let controller = MainViewController(); _ = controller.view; controller.openDocumentURL = source
        controller.pdfView.setMarkupDocument(document)
        let session = controller.pdfView.rectangleMarkup
        let custom = NSColor(deviceRed: 0.2, green: 0.7, blue: 0.4, alpha: 1)
        let annotation = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 40,y: 40,width: 150,height: 80)))
        session.styleSelected(color: custom, width: 3.75)
        let inspector = controller.rectangleToolbar.propertiesController
        inspector.refresh()
        XCTAssertEqual(inspector.heading.stringValue, "Selected Markup")
        XCTAssertEqual(inspector.weight.doubleValue, 3.75)
        XCTAssertEqual(controller.rectangleToolbar.colorPopup.titleOfSelectedItem, "Custom")
        XCTAssertEqual(controller.rectangleToolbar.widthPopup.titleOfSelectedItem, "3.75 pt")
        inspector.weight.objectValue = NSNumber(value: 5.5); inspector.changeNumber(inspector.weight)
        XCTAssertEqual(annotation.border?.lineWidth, 5.5)
        XCTAssertEqual(RectangleMarkupRecord.markupColor(annotation), custom)
        XCTAssertEqual(session.lineWidth, 2)
        session.tool = .text
        inspector.refresh()
        XCTAssertEqual(inspector.heading.stringValue, "New Markup Defaults")
        inspector.fontSize.objectValue = NSNumber(value: 22.5); inspector.changeNumber(inspector.fontSize)
        XCTAssertEqual(session.fontSize, 22.5)
        let text = try XCTUnwrap(session.create(on: page, bounds: CGRect(x: 40,y: 40,width: 150,height: 80), kind: .text, text: "Custom size"))
        session.setFontSize(19.25)
        XCTAssertEqual(text.font?.pointSize, 19.25)
        XCTAssertEqual(session.fontSize, 22.5)
        session.styleSelected(color: custom, width: 2)
        XCTAssertEqual(text.font?.pointSize, 19.25, "Changing color must retain fractional text size")
        let output = source.appendingPathExtension("saved.pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        let records = RectangleMarkupRecord.capture(document)
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: records))
        XCTAssertEqual(RectangleMarkupRecord.capture(try XCTUnwrap(PDFDocument(url: output))), records)
    }
}
