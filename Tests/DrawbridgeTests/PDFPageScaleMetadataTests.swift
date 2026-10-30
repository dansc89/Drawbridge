import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class PDFPageScaleMetadataTests: XCTestCase {
    private var quarter: DrawingScale { DrawingScale.architectural(inches: 0.25, name: "1/4\" = 1'")! }
    private func fixture(separateY: Bool = false) throws -> URL {
        let content = "0 0 0 RG 2 w 100 100 180 90 re S\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 4 /Kids [3 0 R 4 0 R 5 0 R 6 0 R] /MediaBox [10 20 802 632] >>",
            "<< /Type /Page /Parent 2 0 R /Rotate 0 /Contents 11 0 R /Resources << >> /VP [7 0 R 8 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /Rotate 90 /Contents 11 0 R /Resources << >> /VP [7 0 R 8 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /Rotate 180 /Contents 11 0 R /Resources << >> /VP [7 0 R 8 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /Rotate 270 /Contents 11 0 R /Resources << >> /VP [7 0 R 8 0 R] >>",
            "<< /Type /Viewport /BBox [10 20 802 632] /NM (SHEET) /Measure 9 0 R >>",
            "<< /Type /Viewport /BBox [100 100 280 190] /Name (Detail 1) /NM (DETAIL) /Measure 10 0 R >>",
            "<< /Type /Measure /Subtype /RL /R (0.125 in = 1 ft) /X [<< /U (ft) /C 0.1111111 >>] " + (separateY ? "/Y [<< /U (ft) /C 0.2222222 >>] /CYX 1 " : "") + "/D [<< /U (ft) /C 1 /D 8 /F /F >>] /A [<< /U (sf) /C 1 >>] >>",
            "<< /Type /Measure /Subtype /RL /R (0.5 in = 1 ft) /X [<< /U (ft) /C 0.0277777778 >>] /D [<< /U (ft) /C 1 >>] /A [<< /U (sf) /C 1 >>] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (i, value) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(i+1) 0 obj\n\(value)\nendobj\n".utf8)) }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count+1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Page-Scale-\(UUID().uuidString).pdf")
        try data.write(to: url); return url
    }
    private func graph(_ url: URL) throws -> [String: Any] {
        let helper = try XCTUnwrap(PDFTKBookmarkWriter.executableURL())
        let output = url.appendingPathExtension("json"); defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertTrue(PDFTKBookmarkWriter.run(helper, arguments: ["--json", url.path, output.path]))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
    }
    private func table(_ graph: [String: Any]) throws -> [String: Any] { try XCTUnwrap((graph["qpdf"] as? [[String: Any]])?.last) }
    private func page(_ graph: [String: Any], index: Int) throws -> [String: Any] {
        let ref = try XCTUnwrap((graph["pages"] as? [[String: Any]])?[index]["object"] as? String)
        return PDFPageScaleMetadata.dictionary(ref, objects: try table(graph))
    }
    func testExportedImperialEquationPreservesPaperAmountAndCalibration() throws {
        let cases: [(Double,Double,String,String)] = [
            (1,10,"1\" = 10'", "1 in = 10 ft' in\""),
            (1,20,"1″ = 20′-0″", "1 in = 20 ft' in\""),
            (2,20,"2\" = 20'", "2 in = 20 ft' in\""),
            (0.125,1,"1/8\" = 1'", "0.125 in = 1 ft' in\"")]
        for (paper,feet,name,equation) in cases {
            let source=try fixture(),out=source.appendingPathExtension("notation.pdf")
            defer { try? FileManager.default.removeItem(at:source);try? FileManager.default.removeItem(at:out) }
            let original=try Data(contentsOf:source),doc=try XCTUnwrap(PDFDocument(url:source))
            let scale=try XCTUnwrap(DrawingScale.architectural(inches:paper,feet:feet,name:name))
            let session=RectangleMarkupController();session.bind(to:doc)
            session.applyDrawingScale(scale,to:(0..<doc.pageCount).compactMap {doc.page(at:$0)})
            XCTAssertTrue(PDFRectangleWriter.write(document:doc,source:source,destination:out,pageLabels:[:],records:RectangleMarkupRecord.capture(doc)))
            if paper == 1, feet == 10, let path=ProcessInfo.processInfo.environment["DRAWBRIDGE_SCALE_NOTATION_OUTPUT"] {
                try Data(contentsOf:out).write(to:URL(fileURLWithPath:path))
            }
            let saved=try graph(out),objects=try table(saved),reopened=try XCTUnwrap(PDFDocument(url:out))
            for index in 0..<4 {
                let vp=PDFPageScaleMetadata.dictionary(PDFPageScaleMetadata.entries(try page(saved,index:index),objects:objects).first,objects:objects)
                let measure=PDFPageScaleMetadata.dictionary(vp["/Measure"],objects:objects)
                XCTAssertEqual(measure["/R"] as? String,"u:"+equation)
                XCTAssertEqual(try XCTUnwrap(MeasurementMetadata.scale(on:reopened.page(at:index)!)).unitsPerPoint,scale.unitsPerPoint,accuracy:1e-12)
            }
            XCTAssertEqual(try Data(contentsOf:source),original)
        }
    }

    func testSharedBluebeamViewportImportRangeSaveAndDetailPreservation() throws {
        let source = try fixture(), output = source.appendingPathExtension("saved.pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let original = try Data(contentsOf: source), baseline = try graph(source)
        let document = try XCTUnwrap(PDFDocument(url: source)), session = RectangleMarkupController(); session.bind(to: document)
        for i in 0..<4 { XCTAssertEqual(try XCTUnwrap(MeasurementMetadata.scale(on: document.page(at: i)!)).unitsPerPoint, 0.1111111, accuracy: 1e-12) }
        session.applyDrawingScale(quarter, to: [document.page(at: 0)!, document.page(at: 2)!])
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(document), onFailure: { print("SCALE SAVE FAILURE", $0.stage) }))
        XCTAssertEqual(try Data(contentsOf: output).prefix(original.count), original)
        let written = try graph(output), before = try table(baseline), after = try table(written)
        for key in ["obj:7 0 R", "obj:8 0 R", "obj:9 0 R", "obj:10 0 R", "obj:11 0 R"] {
            XCTAssertTrue(NSDictionary(dictionary: before[key] as! [String: Any]).isEqual(to: after[key] as! [String: Any]), key)
        }
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        for i in 0..<4 {
            let value = try XCTUnwrap(MeasurementMetadata.scale(on: reopened.page(at: i)!))
            XCTAssertEqual(value.unitsPerPoint, i % 2 == 0 ? quarter.unitsPerPoint : 0.1111111, accuracy: 1e-12)
            XCTAssertEqual(reopened.page(at: i)?.rotation, i * 90)
            let entries = PDFPageScaleMetadata.entries(try page(written, index: i), objects: after)
            XCTAssertEqual(entries.count, 2); XCTAssertEqual(entries.last as? String, "8 0 R")
        }
        let viewport = PDFPageScaleMetadata.dictionary(PDFPageScaleMetadata.entries(try page(written, index: 0), objects: after).first, objects: after)
        let measure = PDFPageScaleMetadata.dictionary(viewport["/Measure"], objects: after)
        XCTAssertEqual((measure["/D"] as? [[String: Any]])?.first?["/D"] as? Int, 8)
        // The page preservation gate rejects arbitrary calibration changes without an explicit authorization.
        XCTAssertFalse(try PDFRectangleWriter.preservesOriginalObjects(baseline: baseline, updated: written, changed: ["obj:3 0 R"]))
    }
    func testImportedScaleUndoClearRedoAndReopen() throws {
        let source = try fixture(), output = source.appendingPathExtension("saved.pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        let session = RectangleMarkupController(); session.bind(to: document); session.undo.groupsByEvent = false
        func transaction(_ operation: () -> Void) { session.undo.beginUndoGrouping(); operation(); session.undo.endUndoGrouping() }
        transaction { session.applyDrawingScale(quarter, to: [page]) }
        session.undo.undo(); XCTAssertEqual(try XCTUnwrap(MeasurementMetadata.scale(on: page)).unitsPerPoint, 0.1111111, accuracy: 1e-12)
        session.undo.redo(); XCTAssertEqual(MeasurementMetadata.scale(on: page), quarter)
        transaction { session.applyDrawingScale(nil, to: [page]) }
        XCTAssertNil(MeasurementMetadata.scale(on: page))
        XCTAssertFalse(page.annotations.contains(where: MarkupListPresentation.includes))
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(document), onFailure: { print("SCALE SAVE FAILURE", $0.stage) }))
        let reopened = try XCTUnwrap(PDFDocument(url: output)); XCTAssertNil(MeasurementMetadata.scale(on: reopened.page(at: 0)!))
        let graph = try graph(output), objects = try table(graph)
        let entries = PDFPageScaleMetadata.entries(try self.page(graph, index: 0), objects: objects)
        XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries.first as? String, "8 0 R")
        session.undo.undo(); XCTAssertEqual(MeasurementMetadata.scale(on: page), quarter)
    }
    func testUndoAfterSaveRemovesExportedScaleOnSameLiveDocument() throws {
        let source = try fixture(), output = source.appendingPathExtension("saved.pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        let session = RectangleMarkupController(); session.bind(to: document)
        session.applyDrawingScale(nil, to: [page])
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(document)))
        session.applyDrawingScale(quarter, to: [page])
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: output, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(document)))
        session.applyDrawingScale(nil, to: [page])
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: output, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(document)))
        XCTAssertNil(MeasurementMetadata.scale(on: PDFDocument(url: output)!.page(at: 0)!))
    }
    func testMetricScaleRoundTrip() throws {
        let source = try fixture(), output = source.appendingPathExtension("saved.pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let document = try XCTUnwrap(PDFDocument(url: source)), session = RectangleMarkupController(); session.bind(to: document)
        let metric = try XCTUnwrap(DrawingScale.metric(ratio: 100))
        session.applyDrawingScale(metric, to: (0..<4).compactMap(document.page))
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(document), onFailure: { print("SCALE SAVE FAILURE", $0.stage) }))
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        for i in 0..<4 {
            let value = try XCTUnwrap(MeasurementMetadata.scale(on: reopened.page(at: i)!))
            XCTAssertEqual(value.unit, "m"); XCTAssertEqual(value.unitsPerPoint, metric.unitsPerPoint, accuracy: 1e-12)
        }
    }
    func testSeparateAxisScaleDoesNotFallBackToStalePrivateScaleOrChangeOnSave() throws {
        let source = try fixture(separateY: true), output = source.appendingPathExtension("saved.pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        let legacy = PDFAnnotation(bounds: CGRect(x: 10,y: 20,width: 2,height: 2), forType: .square, withProperties: nil)
        legacy.setValue(RectangleMarkupRecord.prefix + UUID().uuidString, forAnnotationKey: RectangleMarkupRecord.identityKey)
        legacy.setValue(MeasurementMetadata.json(quarter), forAnnotationKey: MeasurementMetadata.pageScaleKey)
        legacy.shouldDisplay = false; legacy.shouldPrint = false; legacy.isReadOnly = true; page.addAnnotation(legacy)
        XCTAssertNil(MeasurementMetadata.scale(on: page))
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(document), onFailure: { print("SCALE SAVE FAILURE", $0.stage) }))
        let before = try graph(source), after = try graph(output)
        XCTAssertTrue(NSArray(array: PDFPageScaleMetadata.entries(try self.page(before, index: 0), objects: try table(before))).isEqual(to: PDFPageScaleMetadata.entries(try self.page(after, index: 0), objects: try table(after))))
        XCTAssertNil(MeasurementMetadata.scale(on: PDFDocument(url: output)!.page(at: 0)!))
    }
    func testEquivalentAxisUnitsAndInvalidConversions() throws {
        let measure: [String: Any] = ["/Subtype": "/RL", "/R": "u:1 in = 8 ft",
            "/X": [["/U": "u:ft", "/C": 1.0 / 9]],
            "/Y": [["/U": "u:in", "/C": 12.0 / 9]], "/CYX": 1.0 / 12]
        XCTAssertEqual(try XCTUnwrap(PDFPageScaleMetadata.scale(measure, objects: [:])).unitsPerPoint, 1.0 / 9, accuracy: 1e-12)
        var invalid = measure; invalid["/CYX"] = 2
        XCTAssertNil(PDFPageScaleMetadata.scale(invalid, objects: [:]))
        invalid = measure; invalid["/X"] = [["/U": "u:ft", "/C": -1]]
        XCTAssertNil(PDFPageScaleMetadata.scale(invalid, objects: [:]))
        invalid = measure; invalid["/Subtype"] = "/GEO"
        XCTAssertNil(PDFPageScaleMetadata.scale(invalid, objects: [:]))
    }
    func testOptionalBluebeamDocumentScaleSave() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_BLUEBEAM_SCALE_PDF"],
              let directory = ProcessInfo.processInfo.environment["DRAWBRIDGE_SCALE_QA_DIR"] else { throw XCTSkip("Optional local interoperability fixture") }
        let source = URL(fileURLWithPath: path), output = URL(fileURLWithPath: directory).appendingPathComponent("Bluebeam-Scale-Transfer.pdf")
        let original = try Data(contentsOf: source), document = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(document.pageCount, 4)
        XCTAssertEqual(try XCTUnwrap(MeasurementMetadata.scale(on: document.page(at: 0)!)).unitsPerPoint, 0.1111111, accuracy: 1e-12)
        let session = RectangleMarkupController(); session.bind(to: document)
        session.applyDrawingScale(quarter, to: [document.page(at: 0)!, document.page(at: 2)!])
        let eighth = DrawingScale.architectural(inches: 0.125, name: "1/8\" = 1'")!
        session.applyDrawingScale(eighth, to: [document.page(at: 1)!, document.page(at: 3)!])
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(document), onFailure: { print("SCALE SAVE FAILURE", $0.stage) }))
        XCTAssertEqual(try Data(contentsOf: output).prefix(original.count), original)
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        for i in 0..<4 { XCTAssertEqual(try XCTUnwrap(MeasurementMetadata.scale(on: reopened.page(at: i)!)).unitsPerPoint, i % 2 == 0 ? quarter.unitsPerPoint : eighth.unitsPerPoint, accuracy: 1e-12) }
    }
}
