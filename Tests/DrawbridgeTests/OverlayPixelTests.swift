import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class OverlayPixelTests: XCTestCase {
    private let box = CGRect(x: 0, y: 0, width: 100, height: 100)

    private func pdf(upper: Bool) throws -> Data {
        let data = NSMutableData(); var media = box
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let c = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        c.beginPDFPage(nil)
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(box)
        if upper {
            c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            c.fill(CGRect(x: 40, y: 0, width: 10, height: 100))
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            c.fill(CGRect(x: 70, y: 0, width: 10, height: 100))
        } else {
            c.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            c.fill(CGRect(x: 0, y: 40, width: 100, height: 20))
        }
        c.endPDFPage(); c.closePDF(); return data as Data
    }

    private func image(_ draw: (CGContext) -> Void) throws -> CGImage {
        let c = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
            bytesPerRow: 400, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        draw(c); return try XCTUnwrap(c.makeImage())
    }

    private func assertPixel(_ image: CGImage, _ x: Int, _ y: Int, _ expected: [Int], _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let i = y * image.bytesPerRow + x * 4
        let actual = (0..<4).map { Int(data[i + $0]) }
        for channel in 0..<4 {
            XCTAssertEqual(actual[channel], expected[channel], accuracy: 3, "\(message): \(actual)", file: file, line: line)
        }
    }

    private func sourcePixel(upper: Bool, x: Int, y: Int) throws -> [Int] {
        let page = try XCTUnwrap(SnapshotPayload(data: pdf(upper: upper)).page)
        let rendered = try image { $0.drawPDFPage(page) }
        let data = try XCTUnwrap(rendered.dataProvider?.data) as Data
        return (0..<4).map { Int(data[y * rendered.bytesPerRow + x * 4 + $0]) }
    }

    private func check(_ image: CGImage, overlay: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        // Compare against native PDF source pixels rather than assumed device-RGB
        // values: ColorSync maps device primaries on wide-gamut test hosts.
        let blue = try sourcePixel(upper: false, x: 20, y: 45)
        let red = try sourcePixel(upper: true, x: 45, y: 20)
        try assertPixel(image, 20, 45, overlay ? blue : [255, 255, 255, 255], "Lower blue line through upper white", file: file, line: line)
        try assertPixel(image, 45, 20, red, "Upper red stays fully saturated", file: file, line: line)
        try assertPixel(image, 45, 45, red, "Upper red does not darken/fade at crossing", file: file, line: line)
        try assertPixel(image, 75, 45, [0, 0, 0, 255], "Upper black stays opaque", file: file, line: line)
        try assertPixel(image, 20, 20, [255, 255, 255, 255], "Empty paper remains white", file: file, line: line)
    }

    func testInspectorOverlaySurvivesIsolatedLiveStampSurfaceWithoutFadingInk() throws {
        let document = try XCTUnwrap(PDFDocument(data: pdf(upper: false)))
        let page = try XCTUnwrap(document.page(at: 0))
        let view = MarkupPDFView(); view.document = document
        let session = view.rectangleMarkup; session.bind(to: document); session.canEdit = { true }
        let payload = SnapshotPayload(data: try pdf(upper: true))
        _ = try XCTUnwrap(session.pasteSnapshot(payload, on: page, center: CGPoint(x: 50, y: 50)))
        let inspector = MarkupPropertiesViewController(); inspector.session = session; inspector.loadViewIfNeeded(); inspector.refresh()
        for overlay in [false, true, false] {
            if (inspector.snapshotOverlay.state == .on) != overlay { inspector.snapshotOverlay.performClick(nil) }
            let stamp = try XCTUnwrap(session.selected)
            XCTAssertEqual(SnapshotStyle.read(stamp).overlay, overlay)
            XCTAssertEqual(SnapshotStyle.read(stamp).opacity, 1)
            // PDFKit composites a separately rendered annotation surface, not
            // the annotation's blend state, onto the native page background.
            let surface = try image { stamp.draw(with: .mediaBox, in: $0) }
            let rendered = try image { c in c.drawPDFPage(page.pageRef!); c.draw(surface, in: box) }
            try check(rendered, overlay: overlay)
            stamp.shouldDisplay = false
            let hidden = try image { c in
                c.drawPDFPage(page.pageRef!)
                stamp.draw(with: .mediaBox, in: c)
            }
            try assertPixel(hidden, 45, 45, sourcePixel(upper: false, x: 45, y: 45), "Hidden stamp must stay absent")
            stamp.shouldDisplay = true
        }
    }

    func testSavedReopenedAndFlattenedOverlayPreservesNativeLowerLineworkAndUpperInk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OverlayPixels-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.pdf")
        try pdf(upper: false).write(to: input)
        let helper = try XCTUnwrap(PDFTKBookmarkWriter.executableURL())
        for overlay in [false, true] {
            let document = try XCTUnwrap(PDFDocument(url: input)), page = try XCTUnwrap(document.page(at: 0))
            let view = MarkupPDFView(); view.document = document
            let session = view.rectangleMarkup; session.bind(to: document); session.canEdit = { true }
            var payload = SnapshotPayload(data: try pdf(upper: true)); payload.style.overlay = overlay
            _ = try XCTUnwrap(session.pasteSnapshot(payload, on: page, center: CGPoint(x: 50, y: 50)))
            let output = directory.appendingPathComponent("saved-\(overlay).pdf")
            XCTAssertTrue(PDFRectangleWriter.write(document: document, source: input, destination: output,
                pageLabels: [:], records: RectangleMarkupRecord.capture(document)))
            let reopened = try XCTUnwrap(PDFDocument(url: output)), savedPage = try XCTUnwrap(reopened.page(at: 0))
            let savedStamp = try XCTUnwrap(savedPage.annotations.first { SnapshotPayload.read($0) != nil })
            XCTAssertEqual(SnapshotPayload.read(savedStamp)?.data, payload.data)
            XCTAssertEqual(SnapshotStyle.read(savedStamp).overlay, overlay)
            try check(image { savedPage.draw(with: .mediaBox, to: $0) }, overlay: overlay)
            let flattened = directory.appendingPathComponent("flattened-\(overlay).pdf")
            XCTAssertTrue(PDFTKBookmarkWriter.run(helper, arguments: [output.path, "--flatten-annotations=all", flattened.path]))
            let provider = try XCTUnwrap(CGDataProvider(url: flattened as CFURL))
            let saved = try XCTUnwrap(CGPDFDocument(provider)), flatPage = try XCTUnwrap(saved.page(at: 1))
            try check(image { $0.drawPDFPage(flatPage) }, overlay: overlay)
        }
    }
}
