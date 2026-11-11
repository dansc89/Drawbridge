import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

/// Real Core Animation cached content beneath PDFKit's real page layer. Hidden
/// PDFKit views do not publish their WindowServer tiles into cacheDisplay, so a
/// deterministic content-bearing layer exercises the same invalidation boundary.
private final class PolygonCachedTile: CALayer {
    var polygon: PDFAnnotation?
    var draws = 0
    override func draw(in context: CGContext) {
        draws += 1
        context.setFillColor(NSColor.white.cgColor); context.fill(bounds)
        polygon?.draw(with: .mediaBox, in: context)
    }
}

@MainActor final class PolygonRealtimeRenderingTests: XCTestCase {
    func testResizeInvalidatesLayerOnlyCachedPolygonContentWithoutPanOrZoom() throws {
        _ = NSApplication.shared
        let view = MarkupPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        let document = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 320, height: 240), for: .mediaBox)
        document.insert(page, at: 0)
        view.setMarkupDocument(document); view.displayMode = .singlePage
        view.autoScales = false; view.go(to: page)
        window.layoutIfNeeded(); view.layoutDocumentView(); view.layoutSubtreeIfNeeded()
        view.scaleFactor = 3.88
        let session = view.rectangleMarkup
        session.canEdit = { true }; session.undo.groupsByEvent = false
        defer { view.setMarkupDocument(nil); window.contentView = nil; window.close() }
        session.undo.beginUndoGrouping()
        let polygon = try XCTUnwrap(session.createPolyline(on: page, points: [CGPoint(x: 70, y: 70), CGPoint(x: 220, y: 70), CGPoint(x: 220, y: 170), CGPoint(x: 70, y: 170)], closed: true))
        session.fillSelected(NSColor.purple.withAlphaComponent(0.35))
        session.undo.endUndoGrouping()
        session.selected = nil; session.refresh()
        func pageLayer(in v: NSView) -> CALayer? {
            if let layer = v.layer, String(describing: type(of: layer)) == "PDFPageLayer" { return layer }
            return v.subviews.lazy.compactMap { pageLayer(in: $0) }.first
        }
        let host = try XCTUnwrap(pageLayer(in: view), "Exercise the actual PDFKit page-layer boundary")
        let container = CALayer(); container.frame = host.bounds; host.addSublayer(container)
        defer { container.removeFromSuperlayer() }
        let tile = PolygonCachedTile(); tile.frame = host.bounds; tile.contentsScale = 1; tile.polygon = polygon
        container.addSublayer(tile)
        tile.setNeedsDisplay(); tile.displayIfNeeded()
        func pixels(_ layer: CALayer) throws -> Data {
            let width = 320, height = 240
            let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            layer.render(in: ctx)
            return Data(bytes: try XCTUnwrap(ctx.data), count: width * height * 4)
        }
        let before = try pixels(tile), draws = tile.draws
        XCTAssertGreaterThan(draws, 0)
        // Content control: the cached tile really includes translucent polygon ink.
        XCTAssertTrue(before.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in bytes[100 * 320 * 4 + 100 * 4 + 1] < 245 })
        let scale = view.scaleFactor, rotation = page.rotation, identity = RectangleMarkupRecord.identity(polygon)
        session.undo.beginUndoGrouping()
        session.setBounds(polygon.bounds.insetBy(dx: -20, dy: -10), of: polygon, on: page, action: "Resize")
        session.undo.endUndoGrouping()
        XCTAssertTrue(tile.needsDisplay(), "Mutation must invalidate cached layer-only content, not merely its NSView ancestor")
        tile.displayIfNeeded()
        let after = try pixels(tile)
        XCTAssertGreaterThan(tile.draws, draws)
        XCTAssertNotEqual(before, after, "Actual cached polygon pixels must change before navigation")
        let fresh = PolygonCachedTile(); fresh.frame = tile.frame; fresh.contentsScale = 1; fresh.polygon = polygon
        fresh.setNeedsDisplay(); fresh.displayIfNeeded()
        XCTAssertEqual(after, try pixels(fresh), "Invalidated content must equal freshly drawn geometry")
        XCTAssertEqual(view.scaleFactor, scale); XCTAssertEqual(page.rotation, rotation)
        XCTAssertEqual(RectangleMarkupRecord.identity(polygon), identity)
        session.undo.undo(); tile.displayIfNeeded()
        XCTAssertEqual(try pixels(tile), before, "Undo must invalidate old tiles too")
        session.undo.redo(); tile.displayIfNeeded()
        XCTAssertEqual(try pixels(tile), after, "Redo must invalidate old tiles too")
        XCTAssertFalse(window.isVisible)
    }
}
