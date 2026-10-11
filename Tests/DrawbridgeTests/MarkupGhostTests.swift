import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class MarkupGhostTests: XCTestCase {
    func grouped<T>(_ session: RectangleMarkupController, _ body: () throws -> T) rethrows -> T {
        session.undo.beginUndoGrouping(); defer { session.undo.endUndoGrouping() }; return try body()
    }
    func testSavedPolylinePolygonAndSnapshotMoveDeleteUndoLeaveNoOldGraphics() throws {
        _ = NSApplication.shared
        for kind in [RectangleMarkupRecord.Kind.polyline, .polygon, .snapshot] {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent("Ghost-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: source) }
            var media = CGRect(x: 0, y: 0, width: 500, height: 400)
            let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &media, nil))
            for index in 0..<2 {
                context.beginPDFPage(nil); context.setFillColor(NSColor.white.cgColor); context.fill(media)
                if index == 0 { context.setFillColor(NSColor.black.cgColor); context.fill(CGRect(x: 100,y:100,width:80,height:60)) }
                context.endPDFPage()
            }
            context.closePDF()
            let original = try XCTUnwrap(PDFDocument(url: source)), view = MarkupPDFView(frame: media)
            view.document = original; let c = view.rectangleMarkup; c.bind(to: original); c.canEdit = {true}; c.undo.groupsByEvent = false
            let page = original.page(at: 1)!, bounds = CGRect(x:100,y:100,width:80,height:60)
            if kind == .snapshot {
                let payload = try SnapshotPayload.capture(page: original.page(at: 0)!, points: [CGPoint(x:100,y:100),CGPoint(x:180,y:100),CGPoint(x:180,y:160),CGPoint(x:100,y:160)])
                _ = try XCTUnwrap(grouped(c) { c.pasteSnapshot(payload, on: page, center: CGPoint(x:140,y:130)) })
            } else {
                _ = try XCTUnwrap(grouped(c) { c.create(on:page,bounds:bounds.insetBy(dx:-2,dy:-2),kind:kind,vertices:[CGPoint(x:100,y:100),CGPoint(x:180,y:100),CGPoint(x:180,y:160)]) })
            }
            func save(_ document: PDFDocument) {
                XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: source, pageLabels: [:], records: RectangleMarkupRecord.capture(document)))
            }
            save(original)
            let reopened = try XCTUnwrap(PDFDocument(url: source)); view.document = reopened; c.bind(to: reopened)
            let target = reopened.page(at: 1)!, a = try XCTUnwrap(target.annotations.first { RectangleMarkupRecord.owns($0) })
            c.selectFromList(a)
            func ink(_ page: PDFPage, in region: CGRect) throws -> Int {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: page.thumbnail(of:media.size, for:.mediaBox).tiffRepresentation!))
                var count = 0
                for y in Int(region.minY)..<Int(region.maxY) { for x in Int(region.minX)..<Int(region.maxX) {
                    let color = try XCTUnwrap(bitmap.colorAt(x:x,y:399-y)?.usingColorSpace(.deviceRGB))
                    if min(color.redComponent,color.greenComponent,color.blueComponent) < 0.8 { count += 1 }
                } }
                return count
            }
            let oldRegion = bounds.insetBy(dx:-5,dy:-5), newRegion = oldRegion.offsetBy(dx:200,dy:0)
            XCTAssertGreaterThan(try ink(target, in:oldRegion), 40, "Saved \(kind) is visible")
            grouped(c) { c.setBounds(a.bounds.offsetBy(dx:200,dy:0), of:a, on:target, action:"Move Markup") }
            XCTAssertEqual(try ink(target, in:oldRegion), 0, "Live old \(kind) location is clean")
            XCTAssertGreaterThan(try ink(target, in:newRegion), 40)
            save(reopened)
            let moved = try XCTUnwrap(PDFDocument(url:source)); XCTAssertEqual(try ink(moved.page(at:1)!, in:oldRegion), 0)
            c.undo.undo(); XCTAssertGreaterThan(try ink(target, in:oldRegion), 40); XCTAssertEqual(try ink(target, in:newRegion), 0)
            grouped(c) { c.deleteSelected() }
            XCTAssertEqual(try ink(target, in:oldRegion), 0); XCTAssertEqual(try ink(target, in:newRegion), 0)
            save(reopened)
            let deleted = try XCTUnwrap(PDFDocument(url:source)); XCTAssertTrue(deleted.page(at:1)!.annotations.isEmpty)
            XCTAssertEqual(try ink(deleted.page(at:1)!, in:oldRegion), 0)
            c.undo.undo(); XCTAssertGreaterThan(try ink(target, in:oldRegion), 40)
        }
    }
}
