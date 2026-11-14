import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class SnapshotVectorPresentationTests: XCTestCase {
    private func fixture(raster: Bool = false, segments: Int = 2000) throws -> SnapshotPayload {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 2048, height: 1536)
        let c = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &media, nil))
        c.beginPDFPage(nil)
        if raster {
            let bitmap = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            bitmap.setFillColor(CGColor(gray: 0, alpha: 1))
            for x in stride(from: 0, to: 16, by: 2) { bitmap.fill(CGRect(x: x, y: 0, width: 1, height: 16)) }
            c.draw(try XCTUnwrap(bitmap.makeImage()), in: media)
        } else {
            c.setStrokeColor(CGColor(gray: 0, alpha: 1)); c.setLineWidth(0.075)
            // Fine line pairs and diagonals which cannot survive a 1024px whole-sheet preview.
            for n in 0..<segments {
                let x = CGFloat(n % 1000) * 0.27 + 490.13
                c.move(to: CGPoint(x: x, y: 380)); c.addLine(to: CGPoint(x: x + 9, y: 550)); c.strokePath()
            }
            c.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
            c.fill(CGRect(x: 510, y: 410, width: 7, height: 5))
        }
        c.endPDFPage(); c.closePDF()
        // Give each test its own cache identity, without changing PDF content.
        return SnapshotPayload(data: (data as Data) + Data(("\n%" + UUID().uuidString).utf8))
    }

    private func render(region: CGRect, density: CGFloat, name: String, _ body: (CGContext) -> Void) throws -> [UInt8] {
        let width = Int((region.width * density).rounded()), height = Int((region.height * density).rounded())
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let c = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            c.scaleBy(x: density, y: density); c.translateBy(x: -region.minX, y: -region.minY); c.clip(to: region)
            // Nil NSGraphicsContext with a bitmap is the existing screen-path discriminator.
            // No vector/preview scope is used for the actual annotation draw.
            let previous = NSGraphicsContext.current; NSGraphicsContext.current = nil
            defer { NSGraphicsContext.current = previous }
            body(c)
            let phase = ProcessInfo.processInfo.environment["SNAPSHOT_EVIDENCE_PHASE"] ?? "latest"
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/vector-review-improvements/snapshot-fixtures/" + phase)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let image = NSBitmapImageRep(cgImage: try XCTUnwrap(c.makeImage()))
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
        }
        return pixels
    }

    private func assertMatches(_ actual: [UInt8], _ expected: [UInt8], label: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        var mismatches = 0, ink = 0
        for i in stride(from: 0, to: expected.count, by: 4) {
            if expected[i + 3] > 24 { ink += 1 }
            if (0..<4).contains(where: { abs(Int(actual[i + $0]) - Int(expected[i + $0])) > 12 }) { mismatches += 1 }
        }
        let fraction = Double(mismatches) / Double(expected.count / 4)
        print("SNAPSHOT_PIXELS \(label) mismatch_fraction=\(fraction) reference_ink=\(ink)")
        XCTAssertGreaterThan(ink, 100, "Reference must contain visible detail", file: file, line: line)
        XCTAssertLessThan(fraction, 0.001, "First screen draw must resolve direct-PDF fine detail immediately", file: file, line: line)
    }

    private func compare(payload: SnapshotPayload, rotation: Int = 0, style: SnapshotStyle = SnapshotStyle(),
                         density: CGFloat = 8, tiled: Bool = false, split: Bool = false, label: String) throws {
        let source = try XCTUnwrap(SnapshotPayload(data: SnapshotFilterRenderer.filtered(payload.data, style: style)).page)
        let bounds = CGRect(x: 40, y: 30, width: 2048, height: 1536)
        let transform = SnapshotPayload.transform(size: source.getBoxRect(.mediaBox).size, bounds: bounds, rotation: rotation)
        let region = CGRect(x: 500, y: 400, width: 64, height: 48).applying(transform)
        let original = try XCTUnwrap(SnapshotStampFactory.make(payload: payload, bounds: bounds, rotation: rotation, style: style) as? DrawbridgeSnapshotAnnotation)
        let stamp = split ? try XCTUnwrap(original.splitPresentationCopy()) : original
        let page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 2500, height: 2000), for: .mediaBox)
        page.addAnnotation(stamp)
        let tile = SnapshotViewportTileAnnotation(snapshot: stamp, bounds: region)
        if tiled { stamp.usesViewportTiles = true; page.addAnnotation(tile) }
        let start = CFAbsoluteTimeGetCurrent()
        let actual = try render(region: region, density: density, name: label + "-screen") { c in
            if tiled { tile.draw(with: .mediaBox, in: c) } else { stamp.draw(with: .mediaBox, in: c) }
        }
        print("SNAPSHOT_RENDER \(label) screen_with_png_s=\(CFAbsoluteTimeGetCurrent() - start) payload_bytes=\(payload.data.count)")
        let expected = try render(region: region, density: density, name: label + "-reference") { c in
            c.setAlpha(style.opacity); c.setBlendMode(.normal); c.concatenate(transform)
            c.clip(to: source.getBoxRect(.mediaBox))
            if style.overlay || style.opacity < 1 { c.beginTransparencyLayer(in: c.boundingBoxOfClipPath, auxiliaryInfo: nil) }
            c.drawPDFPage(source)
            if style.overlay || style.opacity < 1 { c.endTransparencyLayer() }
        }
        assertMatches(actual, expected, label: label)
        XCTAssertEqual(stamp.bounds, bounds)
        XCTAssertFalse(tile.shouldPrint)
    }

    func testFirstInteractiveDrawMatchesVectorAtDeviceDensity() throws {
        let payload = try fixture()
        for density: CGFloat in [2, 8, 16] {
            try compare(payload: payload, density: density, label: "fine-\(Int(density))x")
        }
    }

    func testRotatedOpacityOverlayTilesAndSplitCopiesKeepImmediateDetail() throws {
        var style = SnapshotStyle(); style.opacity = 0.45; style.overlay = true
        for rotation in [0, 90, 180, 270] {
            try compare(payload: fixture(), rotation: rotation, style: style, tiled: true, split: true, label: "tile-overlay-\(rotation)")
        }
    }

    func testRasterPayloadMatchesItsActualSourceNotInventedVectorDetail() throws {
        try compare(payload: fixture(raster: true), density: 16, label: "raster-source")
    }

    func testViewportUpdatesDoNotPublishDelayedRasterRefinements() throws {
        let payload = try fixture()
        let stamp = try XCTUnwrap(SnapshotStampFactory.make(payload: payload,
            bounds: CGRect(x: 0, y: 0, width: 2048, height: 1536), rotation: 0) as? DrawbridgeSnapshotAnnotation)
        let key = try XCTUnwrap(stamp.previewKey)
        let noRefinement = expectation(description: "Vector presentation must not queue obsolete raster refinement")
        noRefinement.isInverted = true
        let observer = NotificationCenter.default.addObserver(forName: SnapshotPreviewCache.ready, object: nil, queue: .main) { note in
            if (note.userInfo?["captureKeys"] as? Set<String>)?.contains(key) == true { noRefinement.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for density in [2.0, 4, 8] { stamp.updatePreviewViewport(CGRect(x: 500, y: 400, width: 64, height: 48), deviceScale: density) }
        wait(for: [noRefinement], timeout: 1)
    }
}
