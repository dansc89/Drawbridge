import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

private final class SnapshotRenderEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var renders = [(CGRect, Double, CFAbsoluteTime)]()
    func record(_ region: CGRect, _ scale: Double) {
        lock.lock(); defer { lock.unlock() }
        renders.append((region, scale, CFAbsoluteTimeGetCurrent()))
    }
    var detail: [(CGRect, Double, CFAbsoluteTime)] {
        lock.lock(); defer { lock.unlock() }
        return renders.filter { $0.1 == 2 }
    }
}

@MainActor final class SnapshotTileDemandTests: XCTestCase {
    private func fixture() throws -> Data {
        let output = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 2048, height: 2048)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: output)), mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(0.2)
        for n in 0..<12000 {
            let x = CGFloat((n * 37) % 2048), y = CGFloat((n * 53) % 2048)
            context.move(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x + 120, y: y + 60))
            context.strokePath()
        }
        context.endPDFPage(); context.closePDF()
        return output as Data
    }

    private func run(data: Data, visible: CGRect, expected: Int, trial: Int) throws {
        let evidence = SnapshotRenderEvidence()
        let cache = SnapshotPreviewCache(onRenderCompleted: { evidence.record($0, $1) })
        let page = try XCTUnwrap(SnapshotPayload(data: data).page)
        let key = SnapshotPreviewCache.key(data)
        let preview = try XCTUnwrap(cache.prepare(data, key: key, page: page))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        context.translateBy(x: -visible.minX, y: -visible.minY)
        context.clip(to: visible)
        let ready = expectation(description: "Actual detail publication")
        ready.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(forName: SnapshotPreviewCache.ready, object: nil, queue: .main) { notification in
            if (notification.userInfo?["captureKeys"] as? Set<String>)?.contains(key) == true { ready.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let start = CFAbsoluteTimeGetCurrent()
        cache.draw(data: data, key: key, preview: preview, page: page, visibleRegion: visible, deviceScale: 2, in: context)
        let returned = CFAbsoluteTimeGetCurrent() - start
        wait(for: [ready], timeout: 10)
        let published = CFAbsoluteTimeGetCurrent() - start
        let detail = evidence.detail
        print("SNAPSHOT_DEMAND trial=\(trial) renders=\(detail.count) return_s=\(returned) completion_s=\((detail.last?.2 ?? start) - start) publication_s=\(published)")
        XCTAssertEqual(detail.count, expected, "Only positive-area visible detail tiles should be rendered")
        for (region, scale, _) in detail {
            let overlap = region.intersection(visible)
            XCTAssertGreaterThan(overlap.width * overlap.height, 0, "Do not traverse the vector PDF for an invisible edge tile")
            XCTAssertEqual(scale, 2, "Keep original requested density")
        }
        // Cached redraw must neither traverse the PDF nor announce more work.
        cache.draw(data: data, key: key, preview: preview, page: page, visibleRegion: visible, deviceScale: 2, in: context)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(evidence.detail.count, expected)
    }

    func testAlignedDrawRendersOnlyVisibleTileRepeatedBenchmark() throws {
        let data = try fixture()
        for trial in 1...5 {
            try run(data: data, visible: CGRect(x: 512, y: 512, width: 512, height: 512), expected: 1, trial: trial)
        }
    }

    func testNonalignedDrawRetainsAllFourIntersectingTiles() throws {
        try run(data: fixture(), visible: CGRect(x: 500, y: 500, width: 512, height: 512), expected: 4, trial: 0)
    }
}
