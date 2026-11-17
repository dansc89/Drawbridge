import XCTest
import AppKit
import PDFKit
@testable import Drawbridge

final class SnapshotVectorReplayTests: XCTestCase {
    func source() -> Data {
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 600, height: 600)
        let c = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        c.beginPDFPage(nil)
        for y in 0..<300 { for x in 0..<300 {
            c.setStrokeColor(red: CGFloat(x % 7)/8, green: CGFloat(y % 5)/6, blue: 0.2, alpha: 1)
            c.setLineWidth(0.08 + CGFloat(x % 3)*0.04)
            let xx = CGFloat(x)*2, yy = CGFloat(y)*2
            c.move(to: CGPoint(x: xx+0.13, y: yy+0.27)); c.addLine(to: CGPoint(x: xx+1.71, y: yy+1.39)); c.addLine(to: CGPoint(x: xx+0.31, y: yy+1.83)); c.strokePath()
        }}
        c.endPDFPage(); c.closePDF(); return data as Data
    }
    @MainActor func testTileFidelityAtHighZoomAndQuarterTurns() async throws {
        let data = source(); let document = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        let viewport = SnapshotReplayPreparation.Viewport()
        defer { SnapshotReplayPreparation.shared.update(viewport.id, sources: []) }
        for rotation in [0, 90, 180, 270] {
            let stamp = DrawbridgeSnapshotAnnotation(bounds: CGRect(x: 20, y: 30, width: 600, height: 600), document: document, rotation: rotation, style: SnapshotStyle(overlay: true, opacity: 0.5), previewData: data)
            try await Self.awaitPreparation(of: stamp, in: viewport)
            let page = PDFPage(); page.setBounds(CGRect(x: 0,y: 0,width: 700,height: 700), for: .mediaBox); page.addAnnotation(stamp); stamp.usesViewportTiles = true
            let tile = SnapshotViewportTileAnnotation(snapshot: stamp, bounds: stamp.bounds); page.addAnnotation(tile)
            for density: CGFloat in [2, 8, 16] {
                // Moving the same native display list must not bake placement.
                stamp.bounds.origin.x += 3
                let a = bitmap(), b = bitmap()
                for c in [a,b] { c.scaleBy(x: density,y: density); c.translateBy(x: -stamp.bounds.midX+128/density,y: -stamp.bounds.midY+128/density) }
                Self.assertReplayDraw { tile.draw(with: .mediaBox, in: a) }
                SnapshotPageRendering.vector { stamp.draw(with: .mediaBox, in: b) }
                let aa = a.data!.assumingMemoryBound(to: UInt8.self), bb = b.data!.assumingMemoryBound(to: UInt8.self)
                var delta = 0, ink = 0, transparent = 0, edges = 0
                for i in 0..<65536 {
                    for k in 0..<4 { delta = max(delta, abs(Int(aa[i*4+k])-Int(bb[i*4+k]))) }
                    if bb[i*4+3] > 0 { ink += 1 }; if bb[i*4+3] == 0 { transparent += 1 }
                    if i % 256 > 0 && abs(Int(bb[i*4+3])-Int(bb[(i-1)*4+3])) > 20 { edges += 1 }
                }
                // Public CGLayer replay rounds antialias coverage by 1–2 levels;
                // this NEW comparison does not relax any existing assertion.
                XCTAssertLessThanOrEqual(delta, 2, "rotation=\(rotation) density=\(density)")
                XCTAssertGreaterThan(ink, 100); XCTAssertGreaterThan(transparent, 100); XCTAssertGreaterThan(edges, 100)
            }
        }
    }
    func testReplayExportRemainsVector() throws {
        let data = source(); let doc = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        // Exercise the prepared list directly for resource inspection ONLY;
        // production persistence always keeps the original source bytes.
        let replay = try XCTUnwrap(SnapshotVectorReplay(document: doc, sourceBytes: data.count))
        let out = NSMutableData(); var box = CGRect(x: 0,y: 0,width: 600,height: 600)
        let c = CGContext(consumer: CGDataConsumer(data: out)!, mediaBox: &box, nil)!
        c.beginPDFPage(nil); replay.draw(in: c); c.endPDFPage(); c.closePDF()
        let reopened = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: out as CFData)!))
        var resources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(reopened.page(at: 1)!.dictionary!, "Resources", &resources)
        let counts = Self.resourceCounts(resources)
        XCTAssertGreaterThan(counts.forms, 0); XCTAssertEqual(counts.images, 0)
    }
    private final class Counts { var images = 0; var forms = 0; var depth = 0 }
    private static func resourceCounts(_ resources: CGPDFDictionaryRef?, depth: Int = 0) -> Counts {
        let counts = Counts(); counts.depth = depth; guard depth < 16, let resources else { return counts }
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return counts }
        CGPDFDictionaryApplyFunction(objects, { _, object, info in
            let counts = Unmanaged<Counts>.fromOpaque(info!).takeUnretainedValue()
            var stream: CGPDFStreamRef?; guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
            var name: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(dict, "Subtype", &name), let name {
                if String(cString: name) == "Image" { counts.images += 1 }
                if String(cString: name) == "Form" {
                    counts.forms += 1
                    var nested: CGPDFDictionaryRef?; CGPDFDictionaryGetDictionary(dict,"Resources",&nested)
                    let result = SnapshotVectorReplayTests.resourceCounts(nested, depth: counts.depth + 1)
                    counts.images += result.images; counts.forms += result.forms
                }
            }
        }, Unmanaged.passUnretained(counts).toOpaque())
        return counts
    }
    func bitmap() -> CGContext {
        CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    // Actual production tile callback, with no NSGraphicsContext installed. nil
    // is the worker-thread screen contract, not a drawing replacement seam.
    @MainActor func testActualTileCallbackLatency() async throws {
        // Other AppKit tests may leave a current context on the XCTest thread.
        // Establish the native tile-worker contract locally and restore it.
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = nil
        defer { NSGraphicsContext.current = previous }
        XCTAssertNil(NSGraphicsContext.current)
        let data = source(); let document = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        let t = CFAbsoluteTimeGetCurrent()
        let stamp = DrawbridgeSnapshotAnnotation(bounds: CGRect(x: 0, y: 0, width: 600, height: 600), document: document, rotation: 0, style: SnapshotStyle(), previewData: data)
        let constructionMS = (CFAbsoluteTimeGetCurrent() - t) * 1000
        XCTAssertLessThan(constructionMS, 50)
        let viewport = SnapshotReplayPreparation.Viewport()
        defer { SnapshotReplayPreparation.shared.update(viewport.id, sources: []) }
        try await Self.awaitPreparation(of: stamp, in: viewport)
        print("VECTOR constructionMs=\(constructionMS) readyMs=\((CFAbsoluteTimeGetCurrent()-t)*1000) sourceBytes=\(data.count)")
        let page = PDFPage(); page.setBounds(stamp.bounds, for: .mediaBox); page.addAnnotation(stamp); stamp.usesViewportTiles = true
        let tile = SnapshotViewportTileAnnotation(snapshot: stamp, bounds: CGRect(x: 284, y: 284, width: 32, height: 32)); page.addAnnotation(tile)
        let c = bitmap(); c.scaleBy(x: 8, y: 8); c.translateBy(x: -284, y: -284)
        Self.assertReplayDraw { tile.draw(with: .mediaBox, in: c) }
        var times = [Double]()
        for _ in 0..<30 { c.clear(CGRect(x: 284,y: 284,width: 32,height: 32)); let start = CFAbsoluteTimeGetCurrent(); tile.draw(with: .mediaBox, in: c); times.append((CFAbsoluteTimeGetCurrent()-start)*1000) }
        times.sort(); print("VECTOR callback n=30 p95=\(times[28]) max=\(times.last!)")
        XCTAssertLessThan(times[28], 50); XCTAssertLessThan(times.last!, 250)
        let pixels = c.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan((0..<65536).filter { pixels[$0*4+3] > 0 }.count, 100)
        withExtendedLifetime((page, tile, stamp, document)) {}
    }

    @MainActor
    func testVisibleReplayRetriesWhenLeaseReleasesCapacity() async throws {
        let data = source()
        let document = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        var occupied = try (0..<8).map { _ in
            try XCTUnwrap(SnapshotVectorReplay(document: document, sourceBytes: 1))
        }
        let stamp = DrawbridgeSnapshotAnnotation(bounds: CGRect(x: 0, y: 0, width: 600, height: 600),
            document: document, rotation: 0, style: SnapshotStyle(), previewData: data)
        let source = try XCTUnwrap(stamp.replaySource)
        let firstView = SnapshotReplayPreparation.Viewport()
        let secondView = SnapshotReplayPreparation.Viewport()
        let preparation = SnapshotReplayPreparation.shared
        defer {
            preparation.update(firstView.id, sources: [])
            preparation.update(secondView.id, sources: [])
        }
        preparation.update(firstView.id, sources: [source])
        XCTAssertNil(SnapshotReplayPreparation.lease(source.key))
        occupied.removeLast()
        try await Self.waitForReplay(source.key)
        let firstReplay = try XCTUnwrap(SnapshotReplayPreparation.lease(source.key))
        let copy = try XCTUnwrap(stamp.splitPresentationCopy())
        try await Self.awaitPreparation(of: copy, in: secondView)
        preparation.update(firstView.id, sources: [])
        XCTAssertTrue(SnapshotReplayPreparation.lease(source.key) === firstReplay)
        preparation.update(secondView.id, sources: [])
        XCTAssertNil(SnapshotReplayPreparation.lease(source.key))
        XCTAssertFalse(SnapshotVectorReplay.hasCapacity(for: 1), "Eviction must preserve the charge for active leases")
        withExtendedLifetime((stamp, copy, firstReplay, occupied)) {}
    }

    @MainActor
    static func awaitPreparation(of stamp: DrawbridgeSnapshotAnnotation, in viewport: SnapshotReplayPreparation.Viewport) async throws {
        let source = try XCTUnwrap(stamp.replaySource)
        SnapshotReplayPreparation.shared.update(viewport.id, sources: [source])
        try await waitForReplay(source.key)
    }

    @MainActor
    private static func waitForReplay(_ key: String) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while SnapshotReplayPreparation.lease(key) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = try XCTUnwrap(SnapshotReplayPreparation.lease(key), "Visible Snapshot should have an accelerated replay")
    }

    static func assertReplayDraw(_ draw: () -> Void, file: StaticString = #filePath, line: UInt = #line) {
        let previousContext = NSGraphicsContext.current
        let previousObserver = SnapshotVectorReplay.onDraw
        defer {
            SnapshotVectorReplay.onDraw = previousObserver
            NSGraphicsContext.current = previousContext
        }
        NSGraphicsContext.current = nil
        var hits = 0
        SnapshotVectorReplay.onDraw = { hits += 1 }
        draw()
        XCTAssertEqual(hits, 1, file: file, line: line)
    }
}
