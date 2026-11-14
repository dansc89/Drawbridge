import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

/// Opt-in, bounded caller-thread work measurements. No private fixture is copied.
@MainActor final class SnapshotVectorPerformanceTests: XCTestCase {
    func testArchitecturalFragmentLiveDrawBudget() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_VECTOR_PROFILE_PDF"] else {
            throw XCTSkip("Set DRAWBRIDGE_VECTOR_PROFILE_PDF to qualify live vector callback costs")
        }
        let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)))
        let indexes = Array(Set([0, document.pageCount / 2, document.pageCount - 1])).sorted()
        var samples = [Double]()
        var callbacksWithVisiblePixels = 0
        var resultRows = [[String: Any]]()
        for index in indexes {
            let page = try XCTUnwrap(document.page(at: index))
            let box = page.bounds(for: .cropBox)
            let payload = try SnapshotPayload.capture(page: page, points: [box.origin,
                CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY),
                CGPoint(x: box.minX, y: box.maxY)])
            let destination = PDFPage(); destination.setBounds(box, for: .mediaBox)
            let stamp = try XCTUnwrap(try SnapshotStampFactory.make(payload: payload, bounds: box, rotation: 0) as? DrawbridgeSnapshotAnnotation)
            destination.addAnnotation(stamp); stamp.usesViewportTiles = true
            var rowSamples = [Double]()
            for density: CGFloat in [2, 8, 16] {
                for step in 0..<6 {
                    let span = 1024 / density
                    let x = box.minX + max(0, box.width - span) * CGFloat(step % 3) / 2
                    let y = box.minY + max(0, box.height - span) * CGFloat(step / 3)
                    let region = CGRect(x: x, y: y, width: span, height: span).intersection(box)
                    let tile = SnapshotViewportTileAnnotation(snapshot: stamp, bounds: region)
                    destination.addAnnotation(tile)
                    defer { destination.removeAnnotation(tile) }
                    let context = try XCTUnwrap(CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                        bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.scaleBy(x: density, y: density)
                    context.translateBy(x: -region.minX, y: -region.minY); context.clip(to: region)
                    let previous = NSGraphicsContext.current; NSGraphicsContext.current = nil
                    let start = ProcessInfo.processInfo.systemUptime
                    tile.draw(with: .mediaBox, in: context)
                    let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    NSGraphicsContext.current = previous
                    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
                    if stride(from: 3, to: 4096 * 1024, by: 4).contains(where: { bytes[$0] > 0 }) {
                        callbacksWithVisiblePixels += 1
                    }
                    rowSamples.append(ms); samples.append(ms)
                }
            }
            resultRows.append(["pageIndex": index, "fragmentBytes": payload.data.count, "callbackMilliseconds": rowSamples])
        }
        XCTAssertGreaterThan(callbacksWithVisiblePixels, 0, "Reject a fast no-op caused by an unattached viewport tile")
        let sorted = samples.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        let maxMS = try XCTUnwrap(sorted.last)
        print("SNAPSHOT_VECTOR_PROFILE callbacks=\(samples.count) p95_ms=\(p95) max_ms=\(maxMS)")
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/vector-review-improvements/vector-profile.json")
        let data = try JSONSerialization.data(withJSONObject: ["samples": resultRows, "p95Milliseconds": p95,
            "maxMilliseconds": maxMS, "limitation": "Direct actual live callback; excludes PDFKit layout, total viewport tile count, retained layers and gestures"], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output)
        XCTAssertLessThan(p95, 50, "Dense-sheet live callback p95 must stay below 50ms; investigate before release")
        XCTAssertLessThan(maxMS, 250, "No individual callback may block caller longer than 250ms")
    }
}
