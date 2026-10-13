import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class SnapshotTileAllocationTests: XCTestCase {
    private struct Fixture {
        let window: NSWindow
        let view: MarkupPDFView
        let page: PDFPage
        let snapshots: [DrawbridgeSnapshotAnnotation]
        let above: PDFAnnotation
        var tiles: [SnapshotViewportTileAnnotation] {
            page.annotations.compactMap { $0 as? SnapshotViewportTileAnnotation }
        }
    }

    private func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let bytes = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 600, height: 600)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: bytes)), mediaBox: &media, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: bytes as Data))
        let page = try XCTUnwrap(document.page(at: 0))
        let fragment = try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: bytes as CFData))))
        let snapshots = (0..<2).map { _ in
            DrawbridgeSnapshotAnnotation(bounds: CGRect(x: 200, y: 200, width: 200, height: 200), document: fragment, rotation: 0, style: SnapshotStyle())
        }
        let above = PDFAnnotation(bounds: CGRect(x: 250, y: 250, width: 20, height: 20), forType: .square, withProperties: nil)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = MarkupPDFView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        view.setMarkupDocument(document)
        snapshots.forEach(page.addAnnotation); page.addAnnotation(above)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        view.autoScales = false; view.maxScaleFactor = 64; view.scaleFactor = 24
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded(); view.revealMarkup(snapshots[0])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        view.updateSnapshotViewportTiles()
        let result = Fixture(window: window, view: view, page: page, snapshots: snapshots, above: above)
        XCTAssertFalse(result.tiles.isEmpty)
        XCTAssertTrue(snapshots.allSatisfy { $0.usesViewportTiles })
        return result
    }

    func testUnchangedViewportDoesNotConstructTilesAndPreservesIdentityOrderBenchmark() throws {
        let f = try fixture()
        defer { SnapshotViewportTileAnnotation.onInitialization = nil; f.window.close() }
        let order = f.page.annotations
        var allocations = 0
        SnapshotViewportTileAnnotation.onInitialization = { allocations += 1 }
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<1000 { f.view.updateSnapshotViewportTiles() }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("SNAPSHOT_TILE_BENCH iterations=1000 initialTiles=\(f.tiles.count) constructors=\(allocations) elapsedSeconds=\(elapsed)")
        XCTAssertEqual(allocations, 0, "Unchanged viewport must not construct disposable PDFAnnotations")
        XCTAssertEqual(order.count, f.page.annotations.count)
        XCTAssertTrue(zip(order, f.page.annotations).allSatisfy { $0 === $1 })
    }

    func testChangedGeometryConstructsReplacementTilesInOwnerStackingOrder() throws {
        let f = try fixture()
        defer { SnapshotViewportTileAnnotation.onInitialization = nil; f.window.close() }
        let old = f.tiles
        var allocations = 0
        SnapshotViewportTileAnnotation.onInitialization = { allocations += 1 }
        f.snapshots[0].bounds = f.snapshots[0].bounds.insetBy(dx: 95, dy: 0)
        f.view.updateSnapshotViewportTiles()
        XCTAssertGreaterThan(allocations, 0)
        XCTAssertEqual(allocations, f.tiles.count)
        XCTAssertTrue(old.allSatisfy { !$0.shouldDisplay })
        for (index, owner) in f.snapshots.enumerated() {
            let ownerIndex = try XCTUnwrap(f.page.annotations.firstIndex { $0 === owner })
            let next = index == 0 ? f.snapshots[1] as PDFAnnotation : f.above
            let nextIndex = try XCTUnwrap(f.page.annotations.firstIndex { $0 === next })
            for tile in f.tiles where tile.snapshot === owner {
                let tileIndex = try XCTUnwrap(f.page.annotations.firstIndex { $0 === tile })
                XCTAssertGreaterThan(tileIndex, ownerIndex); XCTAssertLessThan(tileIndex, nextIndex)
            }
        }
    }

    func testHiddenOwnersRemoveTilesWithoutConstructingReplacements() throws {
        let f = try fixture()
        defer { SnapshotViewportTileAnnotation.onInitialization = nil; f.window.close() }
        let old = f.tiles
        var allocations = 0
        SnapshotViewportTileAnnotation.onInitialization = { allocations += 1 }
        f.snapshots.forEach { $0.shouldDisplay = false }
        f.view.updateSnapshotViewportTiles()
        XCTAssertEqual(allocations, 0); XCTAssertTrue(f.tiles.isEmpty)
        XCTAssertTrue(old.allSatisfy { !$0.shouldDisplay })
        XCTAssertTrue(f.snapshots.allSatisfy { !$0.usesViewportTiles })
        XCTAssertTrue(zip(f.page.annotations, f.snapshots + [f.above]).allSatisfy { $0 === $1 })
    }

    func testRemovedOwnersRemoveTilesWithoutConstructingReplacements() throws {
        let f = try fixture()
        defer { SnapshotViewportTileAnnotation.onInitialization = nil; f.window.close() }
        let old = f.tiles
        var allocations = 0
        SnapshotViewportTileAnnotation.onInitialization = { allocations += 1 }
        f.snapshots.forEach(f.page.removeAnnotation)
        f.view.updateSnapshotViewportTiles()
        XCTAssertEqual(allocations, 0); XCTAssertTrue(f.tiles.isEmpty)
        XCTAssertTrue(old.allSatisfy { !$0.shouldDisplay })
        XCTAssertEqual(f.page.annotations.count, 1)
        XCTAssertTrue(f.page.annotations.first === f.above)
    }
}
