import AppKit
import CoreText
import PDFKit
import XCTest
@testable import Drawbridge

/// Synthetic, self-contained qualification; no private drawings or clipboard state.
/// PNG/PDF evidence is deliberately kept under the repository's ignored .build.
@MainActor final class SnapshotVectorIntegrationTests: XCTestCase {
    private let media = CGRect(x: 0, y: 0, width: 240, height: 160)
    private let selection = CGRect(x: 40, y: 30, width: 120, height: 80)

    private func directory(_ name: String) throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/vector-review-improvements/snapshot-integration/" + name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func pdf(blank: Bool = false) throws -> Data {
        let bytes = NSMutableData()
        var box = media
        let c = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: bytes)), mediaBox: &box, nil))
        c.beginPDFPage(nil)
        if !blank {
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(media)
            c.setStrokeColor(CGColor(gray: 0, alpha: 1)); c.setLineWidth(0.055)
            for x in stride(from: 42.13, through: 157, by: 0.47) {
                c.move(to: CGPoint(x: x, y: 32)); c.addLine(to: CGPoint(x: x + 1.7, y: 107)); c.strokePath()
            }
            c.setFillColor(CGColor(red: 0.08, green: 0.3, blue: 0.85, alpha: 1))
            c.fill(CGRect(x: 48, y: 36, width: 5, height: 7))
            let text = NSAttributedString(string: "VECTOR 012345", attributes: [.font: NSFont.systemFont(ofSize: 2.5)])
            c.textPosition = CGPoint(x: 60, y: 42)
            CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), c)
        }
        c.endPDFPage(); c.closePDF()
        return bytes as Data
    }

    private func points(polygon: Bool) -> [CGPoint] {
        let p = [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY),
                 CGPoint(x: selection.maxX, y: selection.maxY), CGPoint(x: selection.minX, y: selection.maxY)]
        return polygon ? Array(p.prefix(3)) : p
    }

    private func pixels(region: CGRect, scale: CGFloat, evidence: URL, draw: (CGContext) -> Void) throws -> [UInt8] {
        let w = Int((region.width * scale).rounded()), h = Int((region.height * scale).rounded())
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let c = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            c.scaleBy(x: scale, y: scale); c.translateBy(x: -region.minX, y: -region.minY); c.clip(to: region)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = nil
            defer { NSGraphicsContext.current = previous }
            draw(c)
            let image = NSBitmapImageRep(cgImage: try XCTUnwrap(c.makeImage()))
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: evidence)
        }
        return pixels
    }

    private func matches(_ actual: [UInt8], _ expected: [UInt8], label: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        guard actual.count == expected.count else { return }
        var different = 0, ink = 0
        for i in stride(from: 0, to: expected.count, by: 4) {
            if expected[i + 3] > 24 && min(expected[i], expected[i + 1], expected[i + 2]) < 220 { ink += 1 }
            if (0..<4).contains(where: { abs(Int(actual[i + $0]) - Int(expected[i + $0])) > 12 }) { different += 1 }
        }
        let fraction = Double(different) / Double(expected.count / 4)
        print("SNAPSHOT_INTEGRATION \(label) mismatch_fraction=\(fraction) reference_ink=\(ink)")
        XCTAssertGreaterThan(ink, 100, "A blank reference must not pass", file: file, line: line)
        XCTAssertLessThan(fraction, 0.01, label, file: file, line: line)
    }

    func testRectangularAndPolygonCaptureResolveRotatedSourceDetailAtHighDensity() throws {
        let root = try directory("capture")
        for rotation in [0, 90, 180, 270] {
            let document = try XCTUnwrap(PDFDocument(data: pdf()))
            let page = try XCTUnwrap(document.page(at: 0)); page.rotation = rotation
            let source = try XCTUnwrap(page.pageRef)
            let size = rotation % 180 == 0 ? media.size : CGSize(width: media.height, height: media.width)
            let transform = source.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
            for polygon in [false, true] {
                let vertices = points(polygon: polygon).map { $0.applying(transform) }
                let origin = CGPoint(x: try XCTUnwrap(vertices.map(\.x).min()), y: try XCTUnwrap(vertices.map(\.y).min()))
                let payload = try SnapshotPayload.capture(page: page, points: points(polygon: polygon))
                let fragment = try XCTUnwrap(payload.page)
                let bounds = fragment.getBoxRect(.mediaBox)
                let label = "r\(rotation)-polygon\(polygon)"
                try payload.data.write(to: root.appendingPathComponent(label + ".pdf"))
                for scale: CGFloat in [2, 16] {
                    let name = label + "-\(Int(scale))x"
                    let actual = try pixels(region: bounds, scale: scale, evidence: root.appendingPathComponent(name + "-capture.png")) { $0.drawPDFPage(fragment) }
                    let expected = try pixels(region: bounds, scale: scale, evidence: root.appendingPathComponent(name + "-source.png")) { c in
                        let path = CGMutablePath()
                        for (i, p) in vertices.enumerated() {
                            let local = CGPoint(x: p.x - origin.x, y: p.y - origin.y)
                            if i == 0 { path.move(to: local) } else { path.addLine(to: local) }
                        }
                        path.closeSubpath(); c.addPath(path); c.clip()
                        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(bounds)
                        c.translateBy(x: -origin.x, y: -origin.y); c.concatenate(transform); c.drawPDFPage(source)
                    }
                    matches(actual, expected, label: name)
                    if polygon { XCTAssertTrue(stride(from: 3, to: actual.count, by: 4).contains { actual[$0] == 0 }, "Polygon exterior must remain transparent") }
                }
            }
        }
    }

    func testReviewRecordRoundTripAndSavedStandardAppearanceRetainHighZoomDetail() throws {
        _ = NSApplication.shared
        // Missing production PDF helper is a qualification failure, not a silent skip.
        let helper = try XCTUnwrap(PDFTKBookmarkWriter.executableURL())
        let root = try directory("review-export")
        let source = try XCTUnwrap(PDFDocument(data: pdf()))
        let payload = try SnapshotPayload.capture(page: XCTUnwrap(source.page(at: 0)), points: points(polygon: true))
        let base = try pdf(blank: true)
        for rotation in [0, 90, 180, 270] {
            for colorized in [false, true] {
                let document = try XCTUnwrap(PDFDocument(data: base)), page = try XCTUnwrap(document.page(at: 0))
                page.rotation = rotation
                let view = MarkupPDFView(); view.document = document
                let session = view.rectangleMarkup; session.bind(to: document); session.canEdit = { true }
                var styled = payload
                styled.style.filter = colorized ? .colorize : .original
                styled.style.overlay = colorized; styled.style.opacity = colorized ? 0.45 : 1
                let stamp = try XCTUnwrap(session.pasteSnapshot(styled, on: page, center: CGPoint(x: 120, y: 80)))
                let records = RectangleMarkupRecord.capture(document)
                XCTAssertEqual(records.count, 1)
                XCTAssertTrue(records.allSatisfy(\.isValid))
                let json = try JSONEncoder().encode(records)
                let decoded = try JSONDecoder().decode([RectangleMarkupRecord].self, from: json)
                XCTAssertEqual(decoded.first?.snapshotData, records.first?.snapshotData)
                let label = "r\(rotation)-color\(colorized)"
                try json.write(to: root.appendingPathComponent(label + ".json"))
                // Export uses a base with the same rotation, as a real Review does.
                let baseDocument = try XCTUnwrap(PDFDocument(data: base))
                try XCTUnwrap(baseDocument.page(at: 0)).rotation = rotation
                let output = root.appendingPathComponent(label + ".pdf")
                try SharedReviewPDFExport.write(basePDF: XCTUnwrap(baseDocument.dataRepresentation()), records: decoded, to: output)
                let reopened = try XCTUnwrap(PDFDocument(url: output)), savedPage = try XCTUnwrap(reopened.page(at: 0))
                let saved = try XCTUnwrap(savedPage.annotations.first { SnapshotPayload.isSnapshot($0) })
                XCTAssertEqual(SnapshotPayload.read(saved)?.data, payload.data)
                XCTAssertEqual(SnapshotStyle.read(saved), styled.style)
                XCTAssertEqual(saved.bounds, stamp.bounds)
                let flattened = root.appendingPathComponent(label + "-flat.pdf")
                XCTAssertTrue(PDFTKBookmarkWriter.run(helper, arguments: [output.path, "--flatten-annotations=all", flattened.path]))
                let cg = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(url: flattened as CFURL))))
                let standardPage = try XCTUnwrap(cg.page(at: 1))
                // Raw CGPDFPage consumes the persisted /AP, never our custom subclass.
                let actual = try pixels(region: stamp.bounds, scale: 16, evidence: root.appendingPathComponent(label + "-saved.png")) { $0.drawPDFPage(standardPage) }
                let expected = try pixels(region: stamp.bounds, scale: 16, evidence: root.appendingPathComponent(label + "-live.png")) { c in
                    SnapshotPageRendering.vector { stamp.draw(with: .mediaBox, in: c) }
                }
                matches(actual, expected, label: label)
            }
        }
    }

    func testMoveResizeUndoAndSplitTilePresentationDoNotMutateVectorPayload() throws {
        _ = NSApplication.shared
        let root = try directory("editing")
        let source = try XCTUnwrap(PDFDocument(data: pdf()))
        let payload = try SnapshotPayload.capture(page: XCTUnwrap(source.page(at: 0)), points: points(polygon: false))
        let document = try XCTUnwrap(PDFDocument(data: pdf(blank: true))), page = try XCTUnwrap(document.page(at: 0))
        let view = MarkupPDFView(); view.document = document
        let session = view.rectangleMarkup; session.bind(to: document); session.canEdit = { true }
        session.undo.groupsByEvent = false
        session.undo.beginUndoGrouping()
        let stamp = try XCTUnwrap(session.pasteSnapshot(payload, on: page, center: CGPoint(x: 100, y: 70)) as? DrawbridgeSnapshotAnnotation)
        session.undo.endUndoGrouping()
        let initial = stamp.bounds
        let changed = CGRect(x: 45, y: 35, width: initial.width * 1.25, height: initial.height * 1.25)
        session.undo.beginUndoGrouping(); session.setBounds(changed, of: stamp, on: page, action: "Resize Snapshot"); session.undo.endUndoGrouping()
        XCTAssertEqual(stamp.bounds, changed)
        session.undo.undo(); XCTAssertEqual(stamp.bounds, initial)
        session.undo.redo(); XCTAssertEqual(stamp.bounds, changed)
        let copy = try XCTUnwrap(stamp.splitPresentationCopy())
        XCTAssertFalse(copy === stamp)
        let splitPage = PDFPage(); splitPage.setBounds(media, for: .mediaBox); splitPage.addAnnotation(copy)
        XCTAssertTrue(stamp.page === page); XCTAssertTrue(copy.page === splitPage)
        let tile = SnapshotViewportTileAnnotation(snapshot: copy, bounds: changed)
        splitPage.addAnnotation(tile); copy.usesViewportTiles = true
        let direct = try pixels(region: changed, scale: 8, evidence: root.appendingPathComponent("edited.png")) { stamp.draw(with: .mediaBox, in: $0) }
        let tiled = try pixels(region: changed, scale: 8, evidence: root.appendingPathComponent("split-tile.png")) { tile.draw(with: .mediaBox, in: $0) }
        matches(tiled, direct, label: "edited split tile")
        XCTAssertFalse(tile.shouldPrint); XCTAssertFalse(RectangleMarkupRecord.owns(tile))
        XCTAssertEqual(RectangleMarkupRecord.capture(document).count, 1)
        XCTAssertEqual(SnapshotPayload.read(stamp)?.data, payload.data)
        session.selectFromList(stamp)
        session.undo.beginUndoGrouping(); session.deleteSelected(); session.undo.endUndoGrouping()
        XCTAssertFalse(page.annotations.contains(stamp))
        XCTAssertTrue(RectangleMarkupRecord.capture(document).isEmpty)
        session.undo.undo(); XCTAssertTrue(page.annotations.contains(stamp))
        XCTAssertEqual(SnapshotPayload.read(stamp)?.data, payload.data)
    }
}
