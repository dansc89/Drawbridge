import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

private final class TileReusePage: PDFPage {
    var additions = 0
    var removals = 0
    override func addAnnotation(_ annotation: PDFAnnotation) {
        additions += 1
        super.addAnnotation(annotation)
    }
    override func removeAnnotation(_ annotation: PDFAnnotation) {
        removals += 1
        super.removeAnnotation(annotation)
    }
}

@MainActor final class SnapshotViewportTileReuseTests: XCTestCase {
    @MainActor private struct Fixture {
        let window: NSWindow
        let view: MarkupPDFView
        let page: TileReusePage
        let owners: [DrawbridgeSnapshotAnnotation]
        let below: PDFAnnotation
        let above: PDFAnnotation
        let clip: NSClipView
        var tiles: [SnapshotViewportTileAnnotation] {
            page.annotations.compactMap { $0 as? SnapshotViewportTileAnnotation }
        }
        var viewport: CGRect { view.convert(view.convert(clip.bounds, from: clip), to: page) }
    }

    private func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 600, height: 600)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1)); context.setLineWidth(0.075)
        for n in 0..<20000 {
            let x = CGFloat((n * 37) % 600), y = CGFloat((n * 53) % 600)
            context.move(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x + 12, y: y + 6)); context.strokePath()
        }
        context.endPDFPage(); context.closePDF()
        let fragment = try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: data as CFData))))
        let page = TileReusePage(); page.setBounds(media, for: .mediaBox)
        let document = PDFDocument(); document.insert(page, at: 0)
        let below = PDFAnnotation(bounds: CGRect(x: 240, y: 240, width: 20, height: 20), forType: .square, withProperties: nil)
        let above = PDFAnnotation(bounds: below.bounds, forType: .square, withProperties: nil)
        page.addAnnotation(below)
        let owners = (0..<2).map { index in
            var style = SnapshotStyle(); style.opacity = 0.45; style.overlay = true
            let owner = DrawbridgeSnapshotAnnotation(bounds: CGRect(x: 50, y: 50, width: 500, height: 500), document: fragment, rotation: index * 90, style: style)
            page.addAnnotation(owner)
            return owner
        }
        page.addAnnotation(above)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false // Never show, activate, or install this synthetic view.
        let view = MarkupPDFView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view); view.setMarkupDocument(document)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        view.autoScales = false; view.maxScaleFactor = 64; view.scaleFactor = 24
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded(); view.revealMarkup(owners[0])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let clip = try XCTUnwrap(view.documentView?.enclosingScrollView?.contentView)
        // Start away from a grid edge, with ample room to pan in either direction.
        clip.scroll(to: clip.bounds.origin)
        view.updateSnapshotViewportTiles()
        let result = Fixture(window: window, view: view, page: page, owners: owners, below: below, above: above, clip: clip)
        XCTAssertFalse(result.tiles.isEmpty)
        XCTAssertTrue(owners.allSatisfy { $0.usesViewportTiles })
        print("TILE_FIXTURE segments=20000 payload_bytes=\(data.length) initial_tiles=\(result.tiles.count) viewport=\(result.viewport)")
        page.additions = 0; page.removals = 0
        return result
    }

    private func assertStack(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let list = f.page.annotations
        XCTAssertTrue(list.first === f.below, file: file, line: line)
        XCTAssertTrue(list.last === f.above, file: file, line: line)
        for (index, owner) in f.owners.enumerated() {
            let start = try XCTUnwrap(list.firstIndex { $0 === owner })
            let end = try XCTUnwrap(list.firstIndex { $0 === (index == 0 ? f.owners[1] as PDFAnnotation : f.above) })
            for tile in f.tiles where tile.snapshot === owner {
                let position = try XCTUnwrap(list.firstIndex { $0 === tile })
                XCTAssertGreaterThan(position, start, file: file, line: line)
                XCTAssertLessThan(position, end, file: file, line: line)
            }
        }
    }

    func testTinyPansInsideSameCellsDoNotAllocateOrReattachAnnotations() throws {
        let f = try fixture()
        defer { SnapshotViewportTileAnnotation.onInitialization = nil; f.window.close() }
        let old = f.page.annotations, origin = f.clip.bounds.origin
        var allocations = 0
        SnapshotViewportTileAnnotation.onInitialization = { allocations += 1 }
        let start = CFAbsoluteTimeGetCurrent()
        for n in 0..<100 {
            f.clip.scroll(to: CGPoint(x: origin.x + (n.isMultiple(of: 2) ? 0.25 : 0), y: origin.y))
            f.view.updateSnapshotViewportTiles()
        }
        print("TILE_TINY iterations=100 initial_tiles=\(f.tiles.count) allocations=\(allocations) additions=\(f.page.additions) removals=\(f.page.removals) elapsed_s=\(CFAbsoluteTimeGetCurrent() - start)")
        XCTAssertEqual(allocations, 0)
        XCTAssertEqual(f.page.additions, 0); XCTAssertEqual(f.page.removals, 0)
        XCTAssertEqual(old.count, f.page.annotations.count)
        XCTAssertTrue(zip(old, f.page.annotations).allSatisfy { $0 === $1 })
        let density = f.view.scaleFactor * f.window.backingScaleFactor
        let span = 1024 / max(density, 1)
        for tile in f.tiles {
            let cell = CGRect(x: floor(tile.bounds.midX / span) * span, y: floor(tile.bounds.midY / span) * span, width: span, height: span)
            let owner = try XCTUnwrap(tile.snapshot)
            XCTAssertEqual(tile.bounds, cell.intersection(owner.bounds).intersection(f.page.bounds(for: f.view.displayBox)))
        }
        try assertStack(f)
    }

    func testCrossingGridBoundaryReusesOverlapAndOnlyAllocatesEnteringCells() throws {
        let f = try fixture()
        defer { SnapshotViewportTileAnnotation.onInitialization = nil; f.window.close() }
        let old = f.tiles
        var allocations = 0
        SnapshotViewportTileAnnotation.onInitialization = { allocations += 1 }
        let start = CFAbsoluteTimeGetCurrent()
        let span = 1024 / (f.view.scaleFactor * f.window.backingScaleFactor)
        let pagePointsPerClipPoint = f.viewport.width / f.clip.bounds.width
        f.clip.scroll(to: CGPoint(x: f.clip.bounds.minX + span / pagePointsPerClipPoint, y: f.clip.bounds.minY))
        f.view.updateSnapshotViewportTiles()
        let overlap = f.tiles.filter { tile in old.contains { $0.snapshot === tile.snapshot && $0.bounds == tile.bounds } }
        let entering = f.tiles.count - overlap.count
        print("TILE_CROSS old=\(old.count) new=\(f.tiles.count) overlap=\(overlap.count) entering=\(entering) allocations=\(allocations) removals=\(f.page.removals) elapsed_s=\(CFAbsoluteTimeGetCurrent() - start)")
        XCTAssertGreaterThan(overlap.count, 0, "Fixture must retain overlapping cells")
        XCTAssertGreaterThan(entering, 0, "Fixture must cross a grid boundary")
        XCTAssertEqual(allocations, entering)
        for tile in overlap { XCTAssertTrue(old.contains { $0 === tile }); XCTAssertTrue(tile.shouldDisplay) }
        for tile in old where !f.tiles.contains(where: { $0 === tile }) { XCTAssertFalse(tile.shouldDisplay) }
        XCTAssertLessThan(f.page.removals, old.count + f.owners.count + 2, "Do not detach the entire annotation stack")
        try assertStack(f)
    }
}
