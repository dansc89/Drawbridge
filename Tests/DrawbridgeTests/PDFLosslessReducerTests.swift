import Foundation
import PDFKit
import XCTest
@testable import Drawbridge

final class PDFLosslessReducerTests: XCTestCase {
    private func fixture(rotation: Int = 0) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReduceTest-\(UUID().uuidString).pdf")
        let pixels = String(repeating: "A", count: 30000)
        let drawing = "q 100 0 0 100 20 30 cm /Im Do Q\n0 0 m 200 150 l S\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 6 0 R /PageLabels << /Nums [0 << /P (A1.00) >>] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 310 220] /CropBox [20 30 280 210] /Rotate \(rotation) /Resources << /XObject << /Im 5 0 R >> >> /Contents 4 0 R /Annots [8 0 R] >>",
            "<< /Length \(drawing.utf8.count) >>\nstream\n\(drawing)endstream",
            "<< /Type /XObject /Subtype /Image /Width 100 /Height 100 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length 30000 >>\nstream\n\(pixels)\nendstream",
            "<< /Type /Outlines /First 7 0 R /Last 7 0 R /Count 1 >>",
            "<< /Title (Sheet A1.00) /Parent 6 0 R /Dest [3 0 R /Fit] >>",
            "<< /Type /Annot /Subtype /Link /Rect [30 40 50 60] /Border [0 0 0] /A << /S /GoTo /D [3 0 R /Fit] >> >>"
        ]
        var data = Data("%PDF-1.7\n".utf8); var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try data.write(to: url)
        return url
    }
    func testLosslessReductionPreservesGeometryNavigationAndImmediatelySaves() throws {
        for rotation in [0, 90, 180, 270] {
            let source = try fixture(rotation: rotation)
            defer { try? FileManager.default.removeItem(at: source) }
            let result = try PDFLosslessReducer.reduce(source: source)
            XCTAssertTrue(result.saved)
            XCTAssertLessThan(result.reducedBytes, result.originalBytes / 2)
            XCTAssertEqual(try Data(contentsOf: source).count, result.reducedBytes)
            let document = try XCTUnwrap(PDFDocument(url: source))
            let page = try XCTUnwrap(document.page(at: 0))
            XCTAssertEqual(page.rotation, rotation)
            XCTAssertEqual(page.bounds(for: .cropBox), CGRect(x: 20, y: 30, width: 260, height: 180))
            XCTAssertEqual(page.label, "A1.00")
            XCTAssertEqual(document.outlineRoot?.child(at: 0)?.label, "Sheet A1.00")
            XCTAssertNotNil((page.annotations.first?.action as? PDFActionGoTo)?.destination.page)
        }
    }
    func testCancelAndConcurrentChangesDoNotOverwrite() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let before = try Data(contentsOf: source)
        XCTAssertThrowsError(try PDFLosslessReducer.reduce(source: source, cancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: source), before)
        let changed = before + Data("\n% External edit".utf8)
        XCTAssertThrowsError(try PDFLosslessReducer.reduce(source: source, progress: { detail in
            if detail.hasPrefix("Compressing") { try? changed.write(to: source) }
        }))
        XCTAssertEqual(try Data(contentsOf: source), changed)
    }
    func testAlreadyCompactFileIsNotReplacedOrEnlarged() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        _ = try PDFLosslessReducer.reduce(source: source)
        let before = try Data(contentsOf: source)
        let report = try PDFLosslessReducer.reduce(source: source)
        XCTAssertFalse(report.saved)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testRealPDFCorpus() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_REDUCE_CORPUS"] else { throw XCTSkip("Set DRAWBRIDGE_REDUCE_CORPUS for real drawing PDFs") }
        let directory = URL(fileURLWithPath: path)
        let output = directory.appendingPathComponent("reduced-output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for source in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where source.pathExtension == "pdf" {
            let copy = output.appendingPathComponent(source.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: source, to: copy)
            let start = Date()
            let report = try PDFLosslessReducer.reduce(source: copy)
            XCTAssertLessThanOrEqual(report.reducedBytes, report.originalBytes)
            print("Lossless reduce \(source.lastPathComponent): \(report.originalBytes) -> \(report.reducedBytes) bytes in \(Date().timeIntervalSince(start))s")
        }
    }
}
