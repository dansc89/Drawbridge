import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class LegacyDimensionMigrationTests: XCTestCase {
    private let staleDrawing = "q 1 0 0 RG 0 0 m 200 0 l S Q\n% legacy unsplit appearance\n"

    func testUnchangedLegacyMetricDistanceRegeneratesAppearance() throws {
        try assertLegacyDistanceRegeneratesAppearance(version: nil)
    }

    func testVersionOneVerticalDistanceRegeneratesAppearance() throws {
        try assertLegacyDistanceRegeneratesAppearance(version: 1)
    }

    private func assertLegacyDistanceRegeneratesAppearance(version: Int?) throws {
        let fixture = try savedFixture(distance: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let executable = try XCTUnwrap(PDFTKBookmarkWriter.executableURL())
        let jsonURL = fixture.directory.appendingPathComponent("legacy.json")
        XCTAssertTrue(PDFTKBookmarkWriter.run(executable, arguments: ["--json=2", "--json-stream-data=inline", fixture.source.path, jsonURL.path]))
        var graph = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        var tables = try XCTUnwrap(graph["qpdf"] as? [[String: Any]])
        var objects = tables[1]
        let annotationKey = try XCTUnwrap(objects.keys.first { key in
            let value = (objects[key] as? [String: Any])?["value"] as? [String: Any]
            return value?["/NM"] as? String == "u:" + fixture.records[0].id
        })
        var annotationObject = try XCTUnwrap(objects[annotationKey] as? [String: Any])
        var annotation = try XCTUnwrap(annotationObject["value"] as? [String: Any])
        let oldAP = try XCTUnwrap((annotation["/AP"] as? [String: Any])?["/N"] as? String)
        // All semantic/style fields are exactly those emitted by the writer.
        // Only the appearance version and stream differ from a current dimension.
        if let version { annotation["/DrawbridgeDimensionAppearanceVersion"] = version }
        else { annotation.removeValue(forKey: "/DrawbridgeDimensionAppearanceVersion") }
        annotationObject["value"] = annotation; objects[annotationKey] = annotationObject
        var streamObject = try XCTUnwrap(objects["obj:" + oldAP] as? [String: Any])
        var stream = try XCTUnwrap(streamObject["stream"] as? [String: Any])
        var dictionary = try XCTUnwrap(stream["dict"] as? [String: Any])
        dictionary.removeValue(forKey: "/Filter"); dictionary.removeValue(forKey: "/DecodeParms")
        dictionary.removeValue(forKey: "/Length")
        stream["dict"] = dictionary; stream["data"] = Data(staleDrawing.utf8).base64EncodedString()
        streamObject["stream"] = stream; objects["obj:" + oldAP] = streamObject
        tables[1] = objects; graph["qpdf"] = tables
        try JSONSerialization.data(withJSONObject: graph, options: [.sortedKeys]).write(to: jsonURL)
        let legacy = fixture.directory.appendingPathComponent("legacy.pdf")
        XCTAssertTrue(PDFTKBookmarkWriter.run(executable, arguments: [fixture.source.path, "--update-from-json=" + jsonURL.path, legacy.path]))
        let document = try XCTUnwrap(PDFDocument(url: legacy))
        XCTAssertEqual(RectangleMarkupRecord.capture(document), fixture.records, "Semantic records must remain unchanged, exercising old-reference reuse")
        XCTAssertEqual(try drawing(document), staleDrawing)
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: legacy, destination: legacy, pageLabels: [:], records: fixture.records))
        let reopened = try XCTUnwrap(PDFDocument(url: legacy))
        XCTAssertEqual(try drawing(reopened), MeasurementAppearance.pdf(fixture.records[0]), "An unchanged legacy metric length still needs the new dimension appearance")
        XCTAssertEqual(RectangleMarkupRecord.capture(reopened), fixture.records)
    }

    func testCurrentDistanceReusesAppearanceWithoutGrowingPDF() throws {
        let fixture = try savedFixture(distance: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let before = try Data(contentsOf: fixture.source)
        let document = try XCTUnwrap(PDFDocument(url: fixture.source))
        XCTAssertEqual(try drawing(document), MeasurementAppearance.pdf(fixture.records[0]))
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: fixture.source, destination: fixture.source, pageLabels: [:], records: fixture.records))
        XCTAssertEqual(try Data(contentsOf: fixture.source), before, "Current appearance must take unchanged-reference reuse")
    }

    func testNonDistanceMeasurementStillReusesAppearanceWithoutGrowingPDF() throws {
        let fixture = try savedFixture(distance: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let before = try Data(contentsOf: fixture.source)
        let document = try XCTUnwrap(PDFDocument(url: fixture.source))
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: fixture.source, destination: fixture.source, pageLabels: [:], records: fixture.records))
        XCTAssertEqual(try Data(contentsOf: fixture.source), before)
    }

    func testOpeningLegacyImperialInkImmediatelyRefreshesContentsAndConsumerDescription() throws {
        let document = PDFDocument(); let page = PDFPage(); document.insert(page, at: 0)
        let points = [CGPoint(x: 80, y: 120), CGPoint(x: 280, y: 120)]
        let original = PDFAnnotation(bounds: CGRect(x: 56, y: 96, width: 248, height: 48), forType: .ink, withProperties: nil)
        original.setValue(RectangleMarkupRecord.prefix + UUID().uuidString, forAnnotationKey: RectangleMarkupRecord.identityKey)
        original.setValue(MeasurementMetadata.json(DrawingMeasurement(kind: .perimeter,
            scale: DrawingScale(unitsPerPoint: 0.07, unit: "ft", name: "legacy"), closed: false)), forAnnotationKey: MeasurementMetadata.measurementKey)
        RectangleMarkupRecord.setVertices(points, on: original)
        original.contents = "Length: 14.00 ft"; page.addAnnotation(original)
        let comment = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .square, withProperties: nil)
        comment.setValue(RectangleMarkupRecord.prefix + UUID().uuidString, forAnnotationKey: RectangleMarkupRecord.identityKey)
        comment.contents = "Keep this non-measurement comment"; page.addAnnotation(comment)
        // PDFKit's renderer drops custom measurement keys. Use the portable writer
        // to serialize the Ink, then restore legacy contents in its PDF dictionary.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyImperial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.pdf")
        var media = CGRect(x: 0, y: 0, width: 400, height: 400)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &media, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: source, pageLabels: [:], records: RectangleMarkupRecord.capture(document)))
        let executable = try XCTUnwrap(PDFTKBookmarkWriter.executableURL())
        let jsonURL = directory.appendingPathComponent("legacy.json")
        XCTAssertTrue(PDFTKBookmarkWriter.run(executable, arguments: ["--json=2", "--json-stream-data=inline", source.path, jsonURL.path]))
        var graph = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        var tables = try XCTUnwrap(graph["qpdf"] as? [[String: Any]])
        var objects = tables[1]
        for key in objects.keys {
            guard var object = objects[key] as? [String: Any], var value = object["value"] as? [String: Any],
                  let id = value["/NM"] as? String else { continue }
            if id == "u:" + RectangleMarkupRecord.identity(original)! { value["/Contents"] = "u:Length: 14.00 ft" }
            if id == "u:" + RectangleMarkupRecord.identity(comment)! { value["/Contents"] = "u:" + comment.contents! }
            object["value"] = value; objects[key] = object
        }
        tables[1] = objects; graph["qpdf"] = tables
        try JSONSerialization.data(withJSONObject: graph).write(to: jsonURL)
        let legacy = directory.appendingPathComponent("legacy.pdf")
        XCTAssertTrue(PDFTKBookmarkWriter.run(executable, arguments: [source.path, "--update-from-json=" + jsonURL.path, legacy.path]))
        let reopened = try XCTUnwrap(PDFDocument(url: legacy))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.contents, "Length: 14.00 ft")
        let controller = RectangleMarkupController(); controller.bind(to: reopened)
        let openedPage = try XCTUnwrap(reopened.page(at: 0))
        let replacement = try XCTUnwrap(openedPage.annotations.first { MeasurementMetadata.measurement($0) != nil })
        XCTAssertTrue(replacement is DrawbridgeMeasuredPathAnnotation)
        XCTAssertEqual(replacement.contents, "14'-0\"")
        XCTAssertEqual(RectangleMarkupRecord.vertices(replacement), points)
        let captured = RectangleMarkupRecord.capture(reopened)
        XCTAssertEqual(captured.first { $0.measurement != nil }?.measurement?.label(points: points), "14'-0\"")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(MarkupClipboard.copy([replacement], to: board))
        let clipboard = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(board.data(forType: MarkupClipboard.type))) as? [String: Any])
        let entry = try XCTUnwrap((clipboard["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["contents"] as? String, "14'-0\"", "Capture must expose the refreshed description, not the obsolete decimal label")
        // Search and CSV export consume annotation.contents directly.
        XCTAssertEqual((replacement.contents ?? "").lowercased(), "14'-0\"")
        XCTAssertEqual(openedPage.annotations.first { MeasurementMetadata.measurement($0) == nil }?.contents, comment.contents)
    }

    private func savedFixture(distance: Bool) throws -> (directory: URL, source: URL, records: [RectangleMarkupRecord]) {
        _ = try XCTUnwrap(PDFTKBookmarkWriter.executableURL(), "qpdf is required for real save/reuse regression")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyDimension-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.pdf")
        var media = CGRect(x: 0, y: 0, width: 400, height: 400)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &media, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFDocument(url: source)); let page = try XCTUnwrap(document.page(at: 0))
        let controller = RectangleMarkupController(); controller.bind(to: document)
        var points = distance ? [CGPoint(x: 120, y: 80), CGPoint(x: 120, y: 280)] : [CGPoint(x: 80, y: 120), CGPoint(x: 280, y: 120)]
        if !distance { points.append(CGPoint(x: 280, y: 220)) }
        _ = try XCTUnwrap(controller.createMeasurement(on: page, points: points, kind: .perimeter, closed: false,
            scale: DrawingScale(unitsPerPoint: 0.07, unit: "m", name: "metric")))
        let records = RectangleMarkupRecord.capture(document)
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: source, pageLabels: [:], records: records))
        return (directory, source, records)
    }

    private func drawing(_ document: PDFDocument) throws -> String {
        let dictionary = try XCTUnwrap(document.page(at: 0)?.pageRef?.dictionary)
        var annotations: CGPDFArrayRef?; XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "Annots", &annotations))
        var annotation: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), 0, &annotation))
        var appearance: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(annotation), "AP", &appearance))
        var stream: CGPDFStreamRef?; XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(appearance), "N", &stream))
        var format = CGPDFDataFormat.raw
        return String(decoding: try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(stream), &format)) as Data, as: UTF8.self)
    }
}
