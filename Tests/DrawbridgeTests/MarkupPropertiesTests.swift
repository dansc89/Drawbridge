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
        XCTAssertEqual(inspector.heading.stringValue, "Markup Properties")
        XCTAssertEqual(inspector.editingContext.stringValue, "Selected markup")
        XCTAssertEqual(inspector.weight.doubleValue, 3.75)
        XCTAssertEqual(controller.rectangleToolbar.colorPopup.titleOfSelectedItem, "Custom")
        XCTAssertEqual(controller.rectangleToolbar.widthPopup.titleOfSelectedItem, "3.75 pt")
        inspector.weight.objectValue = NSNumber(value: 5.5); inspector.changeNumber(inspector.weight)
        XCTAssertEqual(annotation.border?.lineWidth, 5.5)
        XCTAssertEqual(RectangleMarkupRecord.markupColor(annotation), custom)
        XCTAssertEqual(session.lineWidth, 2)
        session.tool = .text
        inspector.refresh()
        XCTAssertEqual(inspector.heading.stringValue, "Markup Properties")
        XCTAssertEqual(inspector.editingContext.stringValue, "New markup defaults")
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
    func testPatternsOpacityAndHeavyWeightsSurviveSaveReopenAndUndo() throws {
        let source = try fixture(), output = source.appendingPathExtension("styled.pdf")
        defer { [source, output].forEach { try? FileManager.default.removeItem(at: $0) } }
        let original = try Data(contentsOf: source)
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        let session = RectangleMarkupController(); session.bind(to: document); session.undo.groupsByEvent = false
        for (index, pattern) in MarkupLinePattern.allCases.enumerated() {
            session.undo.beginUndoGrouping()
            let annotation = try XCTUnwrap(session.createPolyline(on: page, points: [CGPoint(x: 20, y: 20 + index * 35), CGPoint(x: 220, y: 20 + index * 35), CGPoint(x: 150, y: 40 + index * 35)], closed: true))
            session.styleSelected(color: .blue, width: 16)
            session.setLineAppearance(pattern: pattern, opacity: 0.45)
            session.fillSelected(NSColor.red.withAlphaComponent(0.2))
            session.undo.endUndoGrouping()
            XCTAssertEqual(annotation.border?.lineWidth, 16)
            XCTAssertEqual(MarkupStyle.pattern(annotation), pattern)
            XCTAssertEqual(RectangleMarkupRecord.polygonFill(annotation)?.alphaComponent, 0.2)
        }
        let records = RectangleMarkupRecord.capture(document)
        session.undo.undo(); session.undo.redo()
        XCTAssertEqual(RectangleMarkupRecord.capture(document), records)
        XCTAssertEqual(session.linePattern, .solid); XCTAssertEqual(session.strokeOpacity, 1)
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: records))
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(RectangleMarkupRecord.capture(reopened), records)
        session.bind(to: reopened)
        XCTAssertEqual(RectangleMarkupRecord.capture(reopened), records, "Rebinding custom polygons must retain opacity and patterns")
        XCTAssertEqual(try Data(contentsOf: output).prefix(original.count), original)
    }

    func testInkDashAppearanceIsVisibleBeforeAndAfterSaving() throws {
        let source = try fixture(), output = source.appendingPathExtension("dash.pdf")
        defer { [source, output].forEach { try? FileManager.default.removeItem(at: $0) } }
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        let session = RectangleMarkupController(); session.bind(to: document)
        _ = try XCTUnwrap(session.createPolyline(on: page, points: [CGPoint(x: 40, y: 100), CGPoint(x: 360, y: 100)], closed: false))
        func darkPixels(_ page: PDFPage) throws -> Int {
            let image = page.thumbnail(of: NSSize(width: 400, height: 300), for: .mediaBox)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            var count = 0
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent < 0.95 || color.greenComponent < 0.95 || color.blueComponent < 0.95 { count += 1 }
            } }
            return count
        }
        let solid = try darkPixels(page)
        session.setLineAppearance(pattern: .dashed, opacity: 1)
        let dashed = try darkPixels(page)
        XCTAssertLessThan(dashed, Int(Double(solid) * 0.85), "Ink must visibly show gaps in the live page")
        let records = RectangleMarkupRecord.capture(document)
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: records))
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        let saved = try darkPixels(try XCTUnwrap(reopened.page(at: 0)))
        XCTAssertGreaterThan(saved, 0)
        XCTAssertLessThan(saved, Int(Double(solid) * 0.85))
    }

    func testPersistentSidebarLayoutCollapseAndSelectionControls() throws {
        _ = NSApplication.shared
        let controller = MainViewController(); _ = controller.view
        let inspector = controller.rectangleToolbar.propertiesController
        XCTAssertTrue(inspector.parent === controller)
        let split = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSSplitView }.first)
        if inspector.view.isHidden { controller.toggleSidebar() }
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(controller.pdfView.frame.width, 350)
        XCTAssertLessThanOrEqual(inspector.view.frame.width, 420)
        split.setPosition(split.bounds.width - 360, ofDividerAt: 0)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(inspector.view.frame.width, 360, accuracy: 2)
        controller.toggleSidebar(); XCTAssertTrue(inspector.view.isHidden)
        controller.toggleSidebar(); controller.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(inspector.view.isHidden)
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        controller.openDocumentURL = source; controller.pdfView.setMarkupDocument(document)
        let session = controller.pdfView.rectangleMarkup
        controller.toggleSidebar(); XCTAssertTrue(inspector.view.isHidden)
        session.tool = .area
        XCTAssertFalse(inspector.view.isHidden, "Choosing a markup tool must reveal its properties")
        controller.toggleSidebar(); XCTAssertTrue(inspector.view.isHidden)
        session.tool = .pen
        XCTAssertFalse(inspector.view.isHidden, "Switching tools must reopen a hidden inspector")
        session.tool = .area
        inspector.refresh(); XCTAssertTrue(inspector.filled.isEnabled)
        inspector.linePattern.selectItem(at: 3); inspector.strokeOpacity.doubleValue = 35
        inspector.changeAppearance(inspector.strokeOpacity)
        XCTAssertEqual(session.linePattern, .dashDot); XCTAssertEqual(session.strokeOpacity, 0.35)
        let polygon = try XCTUnwrap(session.createPolyline(on: page, points: [CGPoint(x: 40,y: 40), CGPoint(x: 220,y: 40), CGPoint(x: 130,y: 180)], closed: true))
        inspector.refresh(); inspector.fillOpacity.doubleValue = 25; inspector.changeAppearance(inspector.fillOpacity)
        XCTAssertEqual(RectangleMarkupRecord.polygonFill(polygon)?.alphaComponent, 0.25)
        inspector.filled.state = .off; inspector.changeFill(inspector.filled)
        XCTAssertNil(RectangleMarkupRecord.polygonFill(polygon))
    }

    func testTransparentPolygonFillRendersIndependentlyOfStroke() throws {
        let source = try fixture(), output = source.appendingPathExtension("alpha.pdf")
        defer { [source, output].forEach { try? FileManager.default.removeItem(at: $0) } }
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        let session = RectangleMarkupController(); session.bind(to: document)
        _ = try XCTUnwrap(session.createPolyline(on: page, points: [CGPoint(x: 40,y: 40), CGPoint(x: 220,y: 40), CGPoint(x: 130,y: 180)], closed: true))
        session.styleSelected(color: .blue, width: 2)
        session.setLineAppearance(pattern: .dashDot, opacity: 0.6)
        session.fillSelected(NSColor.red.withAlphaComponent(0.25))
        func checkFill(_ page: PDFPage) throws -> NSColor {
            let image = page.thumbnail(of: NSSize(width: 400, height: 300), for: .mediaBox)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            let colors = [100, 200].compactMap { bitmap.colorAt(x: 130, y: $0)?.usingColorSpace(.deviceRGB) }
            let fill = try XCTUnwrap(colors.min { $0.greenComponent < $1.greenComponent })
            XCTAssertEqual(fill.redComponent, 1, accuracy: 0.03)
            // The thumbnail carries the display color profile, so compare live
            // and reopened colors rather than assuming an unmanaged RGB blend.
            XCTAssertGreaterThan(fill.greenComponent, 0.6); XCTAssertLessThan(fill.greenComponent, 0.95)
            XCTAssertGreaterThan(fill.blueComponent, 0.6); XCTAssertLessThan(fill.blueComponent, 0.95)
            return fill
        }
        let live = try checkFill(page)
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(document)))
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        let saved = try checkFill(try XCTUnwrap(reopened.page(at: 0)))
        XCTAssertEqual(saved.greenComponent, live.greenComponent, accuracy: 0.01)
        XCTAssertEqual(saved.blueComponent, live.blueComponent, accuracy: 0.01)
    }

}
