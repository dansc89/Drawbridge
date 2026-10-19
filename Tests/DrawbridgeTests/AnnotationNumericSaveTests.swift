import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class AnnotationNumericSaveTests: XCTestCase {
    private func record(polygon: Bool = false) -> RectangleMarkupRecord {
        var r = RectangleMarkupRecord(id: RectangleMarkupRecord.prefix + UUID().uuidString,
                                      pageIndex: 0, bounds: CGRect(x: 0, y: 0, width: 240, height: 240),
                                      red: 0, green: 0, blue: 1, lineWidth: 2)
        if polygon {
            r.kind = .polygon
            r.vertices = [CGPoint(x: 0.0010030090270812437, y: 40.23456789012345),
                          CGPoint(x: 230.34567890123456, y: 60.45678901234567),
                          CGPoint(x: 120.56789012345678, y: 230.67890123456789)]
        }
        return r
    }

    private func save(_ records: [RectangleMarkupRecord]) throws {
        XCTAssertNotNil(PDFTKBookmarkWriter.executableURL(), "Real qpdf writer is required")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AnnotationNumericSave-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf"), output = root.appendingPathComponent("saved.pdf")
        let blank = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 400, height: 400), for: .mediaBox)
        blank.insert(page, at: 0)
        XCTAssertTrue(blank.write(to: source))
        let original = try Data(contentsOf: source)
        let document = try XCTUnwrap(PDFDocument(url: source))
        var failure: PDFRectangleWriter.SaveFailure?
        let success = PDFRectangleWriter.write(document: document, source: source, destination: output,
                                               pageLabels: [:], records: records, onFailure: { failure = $0 })
        XCTAssertTrue(success, "Real writer rejected valid records at \(failure?.stage ?? "unknown")")
        XCTAssertEqual(try Data(contentsOf: source), original)
        guard success else { return }
        XCTAssertNil(failure)
        XCTAssertTrue(try Data(contentsOf: output).starts(with: original), "Original PDF bytes must be preserved")
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        let actual = RectangleMarkupRecord.capture(reopened)
        XCTAssertEqual(actual.count, records.count)
        for expected in records {
            let saved = try XCTUnwrap(actual.first { $0.id == expected.id })
            XCTAssertEqual(saved.kind, expected.kind)
            XCTAssertEqual(saved.vertices.count, expected.vertices.count)
            for (a, b) in zip(saved.vertices, expected.vertices) {
                XCTAssertEqual(a.x, b.x, accuracy: 1e-12)
                XCTAssertEqual(a.y, b.y, accuracy: 1e-12)
            }
            XCTAssertEqual(saved.strokeOpacity, expected.strokeOpacity, accuracy: 1e-12)
            XCTAssertEqual(saved.fillOpacity, expected.fillOpacity, accuracy: 1e-12)
            XCTAssertEqual(saved.fill?.count, expected.fill?.count)
            for (a, b) in zip(saved.fill ?? [], expected.fill ?? []) { XCTAssertEqual(a, b, accuracy: 1e-12) }
        }
    }

    private func graph(_ record: RectangleMarkupRecord, changing field: String? = nil, to replacement: Any? = nil) throws -> [String: Any] {
        var annotation: [String: Any] = [
            "/NM": "u:" + record.id, "/T": "u:" + record.author, "/Subtype": "/Polygon",
            "/Rect": [0, 0, 240, 240], "/AP": ["/N": "3 0 R"],
            "/DrawbridgeLinePattern": "u:solid", "/DrawbridgeStrokeOpacity": record.strokeOpacity,
            "/DrawbridgeFillOpacity": record.fillOpacity,
            "/Vertices": record.vertices.flatMap { [Double($0.x), Double($0.y)] }
        ]
        annotation["/IC"] = record.fill
        if let field { annotation[field] = replacement }
        let graph: [String: Any] = ["pages": [["object": "1 0 R"]], "qpdf": [["maxobjectid": 3], [
            "obj:1 0 R": ["value": ["/Annots": ["2 0 R"]]],
            "obj:2 0 R": ["value": annotation], "obj:3 0 R": ["stream": ["dict": [:]]]
        ]]]
        // Preserve Foundation's parsed NSNumber representation just as the qpdf reader does.
        return try JSONSerialization.jsonObject(with: PDFJSONPatchEncoder.data(withJSONObject: graph)) as! [String: Any]
    }

    func testParsedCanonicalNumbersMatchWithoutLosingDecimalPrecision() throws {
        var r = record(polygon: true)
        r.fill = [0.0010030090270812437, 0.5, 1]
        r.strokeOpacity = 0.0010030090270812437
        r.fillOpacity = 0.003009027081243731
        XCTAssertTrue(try PDFRectangleWriter.ownedRecordsMatch(graph(r), records: [r]))
    }

    func testMeaningfulGeometryAndStyleChangesRemainRejected() throws {
        var r = record(polygon: true); r.fill = [0.5, 0.5, 1]
        // Use exactly representable control geometry so the baseline check passes before the fix.
        r.vertices = [CGPoint(x: 1, y: 40), CGPoint(x: 230, y: 60), CGPoint(x: 120, y: 230)]
        XCTAssertTrue(try PDFRectangleWriter.ownedRecordsMatch(graph(r), records: [r]))
        let changes: [(String, Any)] = [
            ("/Vertices", [1.01, 40, 230, 60, 120, 230]),
            ("/Vertices", [1, 40, 230, 60]),
            ("/IC", [0.51, 0.5, 1]), ("/IC", [0.5, 0.5]),
            ("/DrawbridgeStrokeOpacity", 0.99), ("/DrawbridgeFillOpacity", 0.99),
            ("/DrawbridgeStrokeOpacity", true), ("/IC", NSNull()),
            ("/DrawbridgeLinePattern", "u:dashed"), ("/Rect", [0, 0, 241, 240])
        ]
        for (field, value) in changes {
            XCTAssertFalse(try PDFRectangleWriter.ownedRecordsMatch(graph(r, changing: field, to: value), records: [r]), field)
        }
    }

    func testFractionalClosedPolygonSaves() throws {
        try save([record(polygon: true)])
    }

    func testFractionalFillRectangleSaves() throws {
        var r = record(); r.fill = [0.0010030090270812437, 0.23456789012345678, 0.34567890123456789]
        try save([r])
    }

    func testFractionalOpacityRectangleSaves() throws {
        var r = record(); r.strokeOpacity = 0.0010030090270812437; r.fillOpacity = 0.34567890123456789
        try save([r])
    }

    func testFractionalPolygonAndFilledRectangleSaveTogether() throws {
        var polygon = record(polygon: true), rectangle = record()
        polygon.fill = [0.0010030090270812437, 0.23456789012345678, 0.34567890123456789]
        rectangle.fill = polygon.fill
        rectangle.strokeOpacity = 0.0010030090270812437; rectangle.fillOpacity = 0.34567890123456789
        try save([polygon, rectangle])
    }
}
