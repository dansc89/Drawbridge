import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class SnapshotVectorColorTests: XCTestCase {
    private func fixture() throws -> SnapshotPayload {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 120, height: 80)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.move(to: .zero); context.addLine(to: CGPoint(x: 120, y: 0))
        context.addLine(to: CGPoint(x: 0, y: 80)); context.closePath(); context.clip()
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(media)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1)); context.setLineWidth(0.06)
        for x in stride(from: 5.13, to: 110, by: 0.53) {
            context.move(to: CGPoint(x: x, y: 5)); context.addLine(to: CGPoint(x: x, y: 70)); context.strokePath()
        }
        // A solid ink swatch checks tint independently of subpixel line coverage.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 1, y: 1, width: 2, height: 2))
        context.endPDFPage(); context.closePDF()
        return SnapshotPayload(data: data as Data)
    }

    private func pixels(_ draw: (CGContext) -> Void, scale: Int) throws -> [UInt8] {
        let width = 120 * scale, height = 80 * scale
        var result = [UInt8](repeating: 0, count: width * height * 4)
        try result.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale)); draw(context)
        }
        return result
    }

    private func assertSourceDetail(_ actual: [UInt8], source: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        var errors = 0, transparentErrors = 0
        for i in stride(from: 0, to: source.count, by: 4) {
            // Red recoloring leaves source luminance in green/blue, while black becomes red.
            if abs(Int(actual[i+1]) - Int(source[i+1])) > 12 { errors += 1 }
            if source[i+3] == 0 && actual[i+3] != 0 { transparentErrors += 1 }
        }
        XCTAssertLessThan(errors, source.count / 4 / 100, "Recoloring must resolve the same fine vector detail as the source at the requested density", file: file, line: line)
        XCTAssertEqual(transparentErrors, 0, "Polygon exterior must remain transparent", file: file, line: line)
        XCTAssertTrue(stride(from: 0, to: actual.count, by: 4).contains { actual[$0] > 240 && actual[$0+1] < 100 }, "Black source ink must become red", file: file, line: line)
    }

    func testColorizeRetainsSourceDetailBeyondFixedRasterResolution() throws {
        let payload = try fixture(), source = try XCTUnwrap(payload.page)
        var style = SnapshotStyle(); style.filter = .colorize
        let filtered = try SnapshotFilterRenderer.filtered(payload.data, style: style)
        let page = try XCTUnwrap(SnapshotPayload(data: filtered).page)
        for scale in [4, 16] {
            let expected = try pixels({ $0.drawPDFPage(source) }, scale: scale)
            let actual = try pixels({ $0.drawPDFPage(page) }, scale: scale)
            assertSourceDetail(actual, source: expected)
        }
        XCTAssertEqual(try SnapshotFilterRenderer.filtered(payload.data, style: SnapshotStyle()), payload.data)
    }

    func testColorizedSavedAppearanceRetainsSourceDetailAndOriginalPayload() throws {
        let payload = try fixture(), sourcePage = try XCTUnwrap(payload.page)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.pdf"), output = directory.appendingPathComponent("saved.pdf")
        // Empty host page so only the stamp contributes to the rendered pixels.
        let bytes = NSMutableData(); var media = CGRect(x: 0, y: 0, width: 120, height: 80)
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        try (bytes as Data).write(to: input)
        let document = try XCTUnwrap(PDFDocument(url: input)), host = try XCTUnwrap(document.page(at: 0))
        var style = SnapshotStyle(); style.filter = .colorize
        let view = MarkupPDFView(); view.document = document
        let session = view.rectangleMarkup; session.bind(to: document); session.canEdit = { true }
        var styledPayload = payload; styledPayload.style = style
        let stamp = try XCTUnwrap(session.pasteSnapshot(styledPayload, on: host, center: CGPoint(x: media.midX, y: media.midY)))
        XCTAssertTrue(RectangleMarkupRecord.owns(stamp))
        XCTAssertEqual(SnapshotPayload.read(stamp)?.data, payload.data)
        XCTAssertTrue(PDFRectangleWriter.write(document: document, source: input, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(document)))
        let reopened = try XCTUnwrap(PDFDocument(url: output)), page = try XCTUnwrap(reopened.page(at: 0))
        XCTAssertEqual(SnapshotPayload.read(try XCTUnwrap(page.annotations.first))?.data, payload.data)
        // Use CGPDFPage rather than the custom live annotation subclass: this
        // exercises the actual saved appearance consumed by other PDF readers.
        let flattened = directory.appendingPathComponent("flattened.pdf")
        let helper = try XCTUnwrap(PDFTKBookmarkWriter.executableURL())
        XCTAssertTrue(PDFTKBookmarkWriter.run(helper, arguments: [output.path, "--flatten-annotations=all", flattened.path]))
        let provider = try XCTUnwrap(CGDataProvider(url: flattened as CFURL))
        let saved = try XCTUnwrap(CGPDFDocument(provider)), rendered = try XCTUnwrap(saved.page(at: 1))
        assertSourceDetail(try pixels({ $0.drawPDFPage(rendered) }, scale: 16), source: try pixels({ $0.drawPDFPage(sourcePage) }, scale: 16))
    }

    func testColorizedLiveVectorOutputRetainsSourceDetail() throws {
        let payload = try fixture(), source = try XCTUnwrap(payload.page)
        var style = SnapshotStyle(); style.filter = .colorize
        let stamp = try SnapshotStampFactory.make(payload: payload, bounds: CGRect(x: 0, y: 0, width: 120, height: 80), rotation: 0, style: style)
        let actual = try pixels({ context in SnapshotPageRendering.vector { stamp.draw(with: .mediaBox, in: context) } }, scale: 16)
        assertSourceDetail(actual, source: try pixels({ $0.drawPDFPage(source) }, scale: 16))
    }
}
