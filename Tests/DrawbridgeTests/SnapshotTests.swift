import AppKit
import PDFKit
import CoreText
import XCTest
@testable import Drawbridge

// Command-line tests do not own the foreground application. Model an active
// document window without stealing focus from a user's open editor.
@MainActor private final class SnapshotKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor final class SnapshotTests: XCTestCase {
    func fixture(rotation: Int = 0) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotFixture-\(UUID().uuidString).pdf")
        var box = CGRect(x: 30,y: 40,width: 500,height: 400)
        let c = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        c.beginPDFPage(nil)
        c.setFillColor(NSColor.white.cgColor); c.fill(box)
        c.setFillColor(NSColor.red.cgColor); c.fill(CGRect(x:80,y:90,width:60,height:40))
        c.setFillColor(NSColor.blue.cgColor); c.fill(CGRect(x:140,y:130,width:60,height:40))
        c.setStrokeColor(NSColor.black.cgColor); c.setLineWidth(0.3)
        for x in stride(from:82,through:198,by:4) { c.move(to:CGPoint(x:x,y:90)); c.addLine(to:CGPoint(x:x,y:170)); c.strokePath() }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string:"VECTOR Snapshot", attributes:[.font:NSFont.systemFont(ofSize:10)]) as CFAttributedString)
        c.textPosition = CGPoint(x:82,y:110); CTLineDraw(line,c)
        c.endPDFPage(); c.closePDF()
        let doc = try XCTUnwrap(PDFDocument(url:url)); doc.page(at:0)!.rotation = rotation
        XCTAssertTrue(doc.write(to:url)); return url
    }
    func capture(_ page:PDFPage, polygon:Bool = false) throws -> SnapshotPayload {
        try SnapshotPayload.capture(page:page,points:polygon ? [CGPoint(x:80,y:90),CGPoint(x:200,y:90),CGPoint(x:80,y:170)] : [CGPoint(x:80,y:90),CGPoint(x:200,y:90),CGPoint(x:200,y:170),CGPoint(x:80,y:170)])
    }
    func testLivePageSpaceDrawingKeepsEntireSnapshotInsideItsBounds() throws {
        let sourceURL = try fixture()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let sourceDocument = try XCTUnwrap(PDFDocument(url: sourceURL))
        let payload = try capture(try XCTUnwrap(sourceDocument.page(at: 0)))
        let fragment = try XCTUnwrap(payload.page)
        for rotation in [0, 90, 180, 270] {
            let destinationURL = try fixture(rotation: rotation)
            defer { try? FileManager.default.removeItem(at: destinationURL) }
            let destination = try XCTUnwrap(PDFDocument(url: destinationURL))
            let page = try XCTUnwrap(destination.page(at: 0))
            let raw = CGRect(x: 250, y: 200, width: rotation % 180 == 0 ? 120 : 80, height: rotation % 180 == 0 ? 80 : 120)
            let stamp = try SnapshotStampFactory.make(payload: payload, bounds: raw, rotation: rotation)
            page.addAnnotation(stamp)
            let size = rotation % 180 == 0 ? CGSize(width: 500, height: 400) : CGSize(width: 400, height: 500)
            let transform = try XCTUnwrap(page.pageRef).getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
            let displayBounds = raw.applying(transform).standardized
            func bitmap(_ draw: (CGContext) -> Void) throws -> NSBitmapImageRep {
                let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(origin: .zero, size: size))
                draw(context)
                return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
            }
            let actual = try bitmap { context in
                context.concatenate(transform)
                context.clip(to: raw)
                context.translateBy(x: page.bounds(for: .mediaBox).minX, y: page.bounds(for: .mediaBox).minY)
                stamp.draw(with: .mediaBox, in: context)
            }
            let expected = try bitmap { context in
                context.translateBy(x: displayBounds.minX, y: displayBounds.minY)
                context.drawPDFPage(fragment)
            }
            var differences = 0
            for y in 0..<actual.pixelsHigh { for x in 0..<actual.pixelsWide {
                let a = try XCTUnwrap(actual.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let b = try XCTUnwrap(expected.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent) > 0.1 { differences += 1 }
            } }
            XCTAssertLessThan(differences, 100, "Live annotation clipping must preserve the complete upright capture, rotation \(rotation)")
        }
    }

    func testEmbeddedRasterCaptureIsNotBlankAfterPasteAndSave() throws {
        _ = NSApplication.shared
        for rotation in [0, 90, 180, 270] {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent("RasterSnapshot-\(UUID().uuidString).pdf")
            let output = source.deletingLastPathComponent().appendingPathComponent("RasterSnapshotSaved-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
            let imageContext = try XCTUnwrap(CGContext(data: nil, width: 240, height: 160, bitsPerComponent: 8, bytesPerRow: 960, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            imageContext.setFillColor(NSColor.red.cgColor)
            imageContext.fill(CGRect(x: 0, y: 0, width: 120, height: 160))
            imageContext.setFillColor(NSColor.blue.cgColor)
            imageContext.fill(CGRect(x: 120, y: 0, width: 120, height: 160))
            let image = try XCTUnwrap(imageContext.makeImage())
            var media = CGRect(x: 0, y: 0, width: 500, height: 400)
            let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &media, nil))
            context.beginPDFPage(nil)
            context.draw(image, in: CGRect(x: 80, y: 90, width: 120, height: 80))
            context.endPDFPage(); context.closePDF()
            let setup = try XCTUnwrap(PDFDocument(url: source))
            try XCTUnwrap(setup.page(at: 0)).rotation = rotation
            XCTAssertTrue(setup.write(to: source))
            let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
            let payload = try capture(page)
            let pixels = try raster(try XCTUnwrap(payload.page), size: try XCTUnwrap(payload.size))
            let colored = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 180 && pixels[$0+1] < 80 || pixels[$0+2] > 180 && pixels[$0+1] < 80 }.count
            XCTAssertGreaterThan(colored, pixels.count / 8, "Embedded raster capture must contain image pixels, rotation \(rotation)")
            let view = MarkupPDFView(); view.document = document
            let session = view.rectangleMarkup; session.bind(to: document); session.canEdit = { true }
            let pasted = try XCTUnwrap(session.pasteSnapshot(payload, on: page, center: CGPoint(x: 300, y: 250)))
            let bounds = pasted.bounds
            let recaptured = try SnapshotPayload.capture(page: page, points: [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY)])
            let recapturedPixels = try raster(try XCTUnwrap(recaptured.page), size: try XCTUnwrap(recaptured.size))
            let recapturedColor = stride(from: 0, to: recapturedPixels.count, by: 4).filter { recapturedPixels[$0] > 180 && recapturedPixels[$0+1] < 80 || recapturedPixels[$0+2] > 180 && recapturedPixels[$0+1] < 80 }.count
            XCTAssertGreaterThan(recapturedColor, recapturedPixels.count / 8, "Capturing a pasted raster annotation must not be blank, rotation \(rotation)")
            XCTAssertTrue(PDFRectangleWriter.write(document: document, source: source, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(document)))
            let reopened = try XCTUnwrap(PDFDocument(url: output))
            let stamp = try XCTUnwrap(reopened.page(at: 0)?.annotations.first { SnapshotPayload.read($0) != nil })
            XCTAssertEqual(SnapshotPayload.read(stamp)?.data, payload.data)
            let savedPage = try XCTUnwrap(reopened.page(at: 0))
            let rendered = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(savedPage.drawbridgeThumbnail(of: CGSize(width: 1000, height: 1000), for: .mediaBox).tiffRepresentation)))
            var coloredCount = 0
            for y in 0..<rendered.pixelsHigh { for x in 0..<rendered.pixelsWide {
                if let color = rendered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.greenComponent < 0.3 && max(color.redComponent, color.blueComponent) > 0.7 { coloredCount += 1 }
            } }
            XCTAssertGreaterThan(coloredCount, 60000, "Source image and pasted image must both render after saving, rotation \(rotation)")
        }
    }
    func testLocalPhotoCaptureContainsVisiblePixels() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_RASTER_FIXTURE"] else { throw XCTSkip("Provide a local photo PDF") }
        let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)))
        let page = try XCTUnwrap(document.page(at: 0))
        let box = page.bounds(for: .cropBox)
        let region = CGRect(x: box.midX - box.width / 8, y: box.midY - box.height / 8, width: box.width / 4, height: box.height / 4)
        for polygon in [false, true] {
            let points = polygon ? [CGPoint(x: region.minX, y: region.minY), CGPoint(x: region.maxX, y: region.minY), CGPoint(x: region.maxX, y: region.maxY)] : [CGPoint(x: region.minX, y: region.minY), CGPoint(x: region.maxX, y: region.minY), CGPoint(x: region.maxX, y: region.maxY), CGPoint(x: region.minX, y: region.maxY)]
            let payload = try SnapshotPayload.capture(page: page, points: points)
            let pixels = try raster(try XCTUnwrap(payload.page), size: try XCTUnwrap(payload.size))
            let source = try XCTUnwrap(page.pageRef)
            let rotation = ((page.rotation % 360) + 360) % 360
            let size = rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
            let transform = source.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
            let vertices = points.map { $0.applying(transform) }
            let minX = vertices.map(\.x).min()!, minY = vertices.map(\.y).min()!
            let expected = try raster(source, size: try XCTUnwrap(payload.size)) { context in
                let path = CGMutablePath()
                for (index, vertex) in vertices.enumerated() {
                    let local = CGPoint(x: vertex.x - minX, y: vertex.y - minY)
                    if index == 0 { path.move(to: local) } else { path.addLine(to: local) }
                }
                path.closeSubpath(); context.addPath(path); context.clip()
                context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(origin: .zero, size: payload.size!))
                context.translateBy(x: -minX, y: -minY); context.concatenate(transform); context.drawPDFPage(source)
            }
            let difference = zip(pixels, expected).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(pixels.count)
            XCTAssertLessThan(difference, 5, "Snapshot must match a direct rendering of the source image, rather than paste blank")
        }
    }
    func raster(_ page:CGPDFPage, size:CGSize, draw: ((CGContext)->Void)? = nil) throws -> [UInt8] {
        let w=Int(size.width*2), h=Int(size.height*2)
        var bytes = [UInt8](repeating:0,count:w*h*4)
        try bytes.withUnsafeMutableBytes { storage in
            let c = try XCTUnwrap(CGContext(data:storage.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            c.scaleBy(x:2,y:2)
            if let draw { draw(c) } else { c.drawPDFPage(page) }
        }
        return bytes
    }
    func testCaptureIsVectorExactSizeAndPolygonIsTransparent() throws {
        _ = NSApplication.shared
        for rotation in [0,90,180,270] {
            let source=try fixture(rotation:rotation); defer { try? FileManager.default.removeItem(at:source) }
            let doc=try XCTUnwrap(PDFDocument(url:source)), page=doc.page(at:0)!
            let box=try capture(page), triangle=try capture(page,polygon:true)
            XCTAssertEqual(box.size,rotation%180 == 0 ? CGSize(width:120,height:80) : CGSize(width:80,height:120))
            let pixels=try raster(box.page!,size:box.size!)
            XCTAssertTrue(stride(from:3,to:pixels.count,by:4).allSatisfy { pixels[$0] == 255 })
            let clipped=try raster(triangle.page!,size:triangle.size!)
            let clear = stride(from:3,to:clipped.count,by:4).filter { clipped[$0] == 0 }.count
            XCTAssertGreaterThan(clear, Int(triangle.size!.width*triangle.size!.height*1.8))
            XCTAssertLessThan(clear, Int(triangle.size!.width*triangle.size!.height*2.2))
            XCTAssertNotNil(box.page)
            XCTAssertLessThan(box.data.count,50_000)
        }
    }
    func testPasteAllRotationsSaveReopenMoveDeleteUndoAndOriginalBytes() throws {
        _ = NSApplication.shared
        let source=try fixture(); defer { try? FileManager.default.removeItem(at:source) }
        var doc=try XCTUnwrap(PDFDocument(url:source)); let payload=try capture(doc.page(at:0)!)
        for rotation in [0,90,180,270] {
            let p=PDFPage(); p.setBounds(CGRect(x:30,y:40,width:500,height:400),for:.mediaBox); p.rotation=rotation; doc.insert(p,at:doc.pageCount)
        }
        XCTAssertTrue(doc.write(to:source)); doc = try XCTUnwrap(PDFDocument(url:source)); let original=try Data(contentsOf:source)
        let view=MarkupPDFView(frame:CGRect(x:0,y:0,width:800,height:600)); view.document=doc
        let session=view.rectangleMarkup; session.canEdit={true}; session.bind(to:doc); session.undo.groupsByEvent=false
        for index in 1..<doc.pageCount {
            session.undo.beginUndoGrouping()
            let stamp=try XCTUnwrap(session.pasteSnapshot(payload,on:doc.page(at:index)!,center:CGPoint(x:250,y:230)))
            session.undo.endUndoGrouping()
            XCTAssertEqual(stamp.bounds.size,index%2 == 1 ? CGSize(width:120,height:80) : CGSize(width:80,height:120))

        }
        let output=source.deletingLastPathComponent().appendingPathComponent("SnapshotSaved-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at:output) }
        let records=RectangleMarkupRecord.capture(doc)
        XCTAssertEqual(records.count,4); XCTAssertTrue(records.allSatisfy(\.isValid))
        XCTAssertTrue(PDFRectangleWriter.write(document:doc,source:source,destination:output,pageLabels:[:],records:records))
        XCTAssertTrue(try Data(contentsOf:output).starts(with:original))
        if ProcessInfo.processInfo.environment["DRAWBRIDGE_SNAPSHOT_QA"] != nil { try? FileManager.default.removeItem(at:URL(fileURLWithPath:"/tmp/Drawbridge-Snapshot-QA.pdf")); try FileManager.default.copyItem(at:output,to:URL(fileURLWithPath:"/tmp/Drawbridge-Snapshot-QA.pdf")) }
        for index in 1..<doc.pageCount {
            let live = doc.page(at:index)!.drawbridgeThumbnail(of:CGSize(width:500,height:500),for:.mediaBox)
            let savedDoc = PDFDocument(url:output)!
            let saved = savedDoc.page(at:index)!.drawbridgeThumbnail(of:CGSize(width:500,height:500),for:.mediaBox)
            let a = NSBitmapImageRep(data:live.tiffRepresentation!)!, b = NSBitmapImageRep(data:saved.tiffRepresentation!)!
            var differences = 0
            for y in 0..<a.pixelsHigh { for x in 0..<a.pixelsWide {
                let c = a.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!, d = b.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                if abs(c.redComponent-d.redComponent)+abs(c.greenComponent-d.greenComponent)+abs(c.blueComponent-d.blueComponent) > 0.1 { differences += 1 }
            } }
            XCTAssertLessThan(differences, 1200, "Fresh appearance matches saved stamp")
        }
        let reopened=try XCTUnwrap(PDFDocument(url:output)); XCTAssertEqual(RectangleMarkupRecord.capture(reopened).map(\.snapshotData), records.map(\.snapshotData))
        view.document=reopened; session.bind(to:reopened)
        for index in 1..<reopened.pageCount {
            let p=reopened.page(at:index)!, stamp=try XCTUnwrap(p.annotations.first { $0.type == "Stamp" })
            XCTAssertEqual(stamp.type, "Stamp")
            let rawDocument=PDFDocument(url:output)!
            let raw=rawDocument.page(at:index)!
            let expected = try XCTUnwrap(NSBitmapImageRep(data:p.drawbridgeThumbnail(of:CGSize(width:500,height:500),for:.mediaBox).tiffRepresentation!))
            let actual = try XCTUnwrap(NSBitmapImageRep(data:raw.drawbridgeThumbnail(of:CGSize(width:500,height:500),for:.mediaBox).tiffRepresentation!))
            XCTAssertEqual(expected.pixelsWide, actual.pixelsWide); XCTAssertEqual(expected.pixelsHigh, actual.pixelsHigh)
            var differences = 0
            for y in 0..<expected.pixelsHigh { for x in 0..<expected.pixelsWide {
                let a=expected.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!, b=actual.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                if abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent) > 0.1 { differences += 1 }
            } }
            if ProcessInfo.processInfo.environment["DRAWBRIDGE_SNAPSHOT_QA"] != nil { try expected.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/snapshot-live-\(p.rotation).png"))
            try actual.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/snapshot-saved-\(p.rotation).png"))
            }
            XCTAssertLessThan(differences, 1200, "Live vs saved appearance, rotation \(p.rotation)")
        }
        let p=reopened.page(at:1)!, stamp=p.annotations.first { $0.type == "Stamp" }!
        session.selectFromList(stamp)
        session.undo.beginUndoGrouping(); session.deleteSelected(); session.undo.endUndoGrouping()
        XCTAssertFalse(p.annotations.contains(stamp)); session.undo.undo(); XCTAssertTrue(p.annotations.contains(stamp))
        XCTAssertTrue(PDFRectangleWriter.write(document:reopened,source:output,destination:output,pageLabels:[:],records:RectangleMarkupRecord.capture(reopened)))
    }
    func testCapturePixelsMatchOriginalAtDifferentZoomLevelsAndIncludesMarkups() throws {
        let source=try fixture(); defer { try? FileManager.default.removeItem(at:source) }
        let document=try XCTUnwrap(PDFDocument(url:source)), page=document.page(at:0)!
        let payload=try capture(page)
        let expected=try raster(page.pageRef!,size:CGSize(width:120,height:80)) { c in
            c.translateBy(x:-80,y:-90); c.drawPDFPage(page.pageRef!)
        }
        let actual=try raster(payload.page!,size:payload.size!)
        XCTAssertLessThan(zip(expected,actual).filter { abs(Int($0.0)-Int($0.1)) > 8 }.count, 100)
        let view=MarkupPDFView(frame:CGRect(x:0,y:0,width:800,height:600)); view.document=document
        view.rectangleMarkup.bind(to:document); view.rectangleMarkup.canEdit={true}
        let markup=try XCTUnwrap(view.rectangleMarkup.create(on:page,bounds:CGRect(x:90,y:100,width:80,height:50)))
        markup.color = .green
        view.scaleFactor = 0.25; let low=try capture(page)
        view.scaleFactor = 4; let high=try capture(page)
        XCTAssertEqual(try raster(low.page!,size:low.size!), try raster(high.page!,size:high.size!))
        XCTAssertNotEqual(actual,try raster(low.page!,size:low.size!))
    }
    func testBoxPolygonCaptureCancelAndFixedSizeThroughController() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:1000,height:900),styleMask:[.titled],backing:.buffered,defer:false)
        let view = MarkupPDFView(frame:window.contentView!.bounds); window.contentView!.addSubview(view)
        for rotation in [0,90,180,270] {
            let source = try fixture(rotation:rotation); defer { try? FileManager.default.removeItem(at:source) }
            let doc = PDFDocument(url:source)!, page = doc.page(at:0)!
            view.setMarkupDocument(doc); view.go(to:page); window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
            let session = view.rectangleMarkup; session.canEdit = { true }
            func location(_ point:CGPoint) -> CGPoint { view.convert(point,from:page) }
            session.tool = .snapshotBox
            XCTAssertTrue(session.pointerDown(at:location(CGPoint(x:80,y:90))))
            XCTAssertTrue(session.pointerDragged(at:location(CGPoint(x:200,y:170))))
            XCTAssertTrue(session.pointerUp(at:location(CGPoint(x:200,y:170))))
            let box = try XCTUnwrap(SnapshotPayload.clipboard())
            XCTAssertEqual(box.size,rotation%180 == 0 ? CGSize(width:120,height:80) : CGSize(width:80,height:120))
            XCTAssertTrue(page.annotations.isEmpty)
            session.tool = .snapshotPolygon
            for p in [CGPoint(x:80,y:90),CGPoint(x:200,y:90),CGPoint(x:80,y:170)] { XCTAssertTrue(session.pointerDown(at:location(p))) }
            XCTAssertTrue(session.finishPolyline())
            let triangle = try XCTUnwrap(SnapshotPayload.clipboard()); XCTAssertNotEqual(triangle.data,box.data)
            session.tool = .snapshotBox; XCTAssertTrue(session.pointerDown(at:location(CGPoint(x:80,y:90))))
            session.cancelGesture(); XCTAssertEqual(SnapshotPayload.clipboard()?.data,triangle.data)
            let stamp = try XCTUnwrap(session.pasteSnapshot(triangle,on:page,center:CGPoint(x:250,y:250)))
            let original = stamp.bounds
            session.setBounds(original.insetBy(dx:-10,dy:-10),of:stamp,on:page,action:"Resize")
            XCTAssertEqual(stamp.bounds,original)
            let originalColor = stamp.color
            session.styleSelected(color:.red,width:6)
            XCTAssertEqual(stamp.color,originalColor)
        }
    }

    func testLargePDFSnapshotsAndRepeatedSaves() throws {
        guard let path=ProcessInfo.processInfo.environment["DRAWBRIDGE_SNAPSHOT_FIXTURE"] else { throw XCTSkip("Provide a large local PDF for performance testing") }
        let source=URL(fileURLWithPath:path), document=try XCTUnwrap(PDFDocument(url:source)), page=document.page(at:0)!
        let box=page.bounds(for:.cropBox), w=box.width/5, h=box.height/5
        let points=[CGPoint(x:box.maxX-w,y:box.minY),CGPoint(x:box.maxX,y:box.minY),CGPoint(x:box.maxX,y:box.minY+h),CGPoint(x:box.maxX-w,y:box.minY+h)]
        let captureStart=Date(); let payload=try SnapshotPayload.capture(page:page,points:points)
        print("Snapshot capture seconds",Date().timeIntervalSince(captureStart),"bytes",payload.data.count)
        let view=MarkupPDFView(); view.document=document; let session=view.rectangleMarkup
        session.bind(to:document); session.canEdit={true}
        for index in 0..<20 {
            let p=document.page(at:index % document.pageCount)!
            XCTAssertNotNil(session.pasteSnapshot(payload,on:p,center:CGPoint(x:p.bounds(for:.cropBox).midX,y:p.bounds(for:.cropBox).midY)))
        }
        XCTAssertTrue(PDFRectangleWriter.prepareInspection(source:source))
        let output=URL(fileURLWithPath:"/tmp/Drawbridge-Snapshot-Large-QA.pdf")
        let start=Date()
        XCTAssertTrue(PDFRectangleWriter.write(document:document,source:source,destination:output,pageLabels:[:],records:RectangleMarkupRecord.capture(document)))
        let elapsed=Date().timeIntervalSince(start); print("Twenty snapshots first save seconds",elapsed)
        // The first save copies the source PDF as well as the new appearance.
        // Keep a five-second floor, with a 40 MiB/s budget for large permit sets.
        let sourceBytes = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertLessThan(elapsed, max(5, Double(sourceBytes) / (40 * 1024 * 1024)))
        let reopened=try XCTUnwrap(PDFDocument(url:output)); XCTAssertEqual(RectangleMarkupRecord.capture(reopened).filter { $0.kind == .snapshot }.count,20)
        let savedData=try Data(contentsOf:output,options:.mappedIfSafe), originalData=try Data(contentsOf:source,options:.mappedIfSafe)
        XCTAssertTrue(savedData.starts(with:originalData))
        let inspection = URL(fileURLWithPath:"/tmp/Drawbridge-Snapshot-Sharing-QA.json")
        let helper = try XCTUnwrap(PDFTKBookmarkWriter.executableURL())
        XCTAssertTrue(PDFTKBookmarkWriter.run(helper,arguments:["--json=2","--json-stream-data=none",output.path,inspection.path]))
        defer { try? FileManager.default.removeItem(at:inspection) }
        let graph = try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:inspection)) as? [String:Any])
        let objects = try XCTUnwrap((graph["qpdf"] as? [[String:Any]])?.last)
        let snapshots = objects.values.compactMap { ($0 as? [String:Any])?["value"] as? [String:Any] }.filter { $0["/DrawbridgeSnapshotPDF"] != nil }
        XCTAssertEqual(snapshots.count,20)
        let payloadReferences = snapshots.compactMap { $0["/DrawbridgeSnapshotPDF"] as? String }
        XCTAssertEqual(Set(payloadReferences).count,1,"Repeated captures share one embedded payload")
        let fragments = snapshots.compactMap { annotation -> String? in
            guard let appearance = (annotation["/AP"] as? [String:Any])?["/N"] as? String,
                  let stream = (objects["obj:" + appearance] as? [String:Any])?["stream"] as? [String:Any],
                  let resources = (stream["dict"] as? [String:Any])?["/Resources"] as? [String:Any] else { return nil }
            return (resources["/XObject"] as? [String:Any])?["/Snapshot"] as? String
        }
        XCTAssertEqual(fragments.count,20)
        XCTAssertEqual(Set(fragments).count,1,"Repeated captures share one appearance fragment")
        view.document=reopened; session.bind(to:reopened)
        let stamp=reopened.page(at:0)!.annotations.first { $0.type == "Stamp" && RectangleMarkupRecord.owns($0) }!
        session.setBounds(stamp.bounds.offsetBy(dx:-5,dy:5),of:stamp,on:stamp.page!,action:"Move Snapshot")
        let second=Date()
        XCTAssertTrue(PDFRectangleWriter.write(document:reopened,source:output,destination:output,pageLabels:[:],records:RectangleMarkupRecord.capture(reopened)))
        print("Snapshot move save seconds",Date().timeIntervalSince(second))
        XCTAssertLessThan(Date().timeIntervalSince(second),5)
    }
    func testClipboardCrossDocumentAndInvalidPayload() throws {
        _ = NSApplication.shared
        let source=try fixture(); defer { try? FileManager.default.removeItem(at:source) }
        let payload=try capture(PDFDocument(url:source)!.page(at:0)!); payload.copy()
        XCTAssertEqual(SnapshotPayload.clipboard()?.data,payload.data)
        XCTAssertEqual(NSPasteboard.general.data(forType:.pdf),payload.data)
        XCTAssertNil(SnapshotPayload(data:Data("bad PDF".utf8)).page)
        let destination=PDFDocument(); let page=PDFPage(); destination.insert(page,at:0)
        let view=MarkupPDFView(); view.document=destination; view.rectangleMarkup.bind(to:destination); view.rectangleMarkup.canEdit={true}
        XCTAssertNotNil(view.rectangleMarkup.pasteSnapshot(payload,on:page,center:CGPoint(x:200,y:200)))
        try FileManager.default.removeItem(at:source)
        XCTAssertNotNil(SnapshotPayload.read(try XCTUnwrap(page.annotations.first))?.page)
    }
    func testUnifiedCameraClickNodesDoubleClickAndPasteInPlace() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:1000,height:900),styleMask:[.titled],backing:.buffered,defer:false)
        let view=MarkupPDFView(frame:window.contentView!.bounds); window.contentView!.addSubview(view)
        for rotation in [0,90,180,270] {
            let source=try fixture(rotation:rotation); defer { try? FileManager.default.removeItem(at:source) }
            let doc=try XCTUnwrap(PDFDocument(url:source)), page=doc.page(at:0)!
            view.setMarkupDocument(doc); view.go(to:page); window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
            let session=view.rectangleMarkup; session.canEdit={true}; session.tool = .snapshotBox
            func point(_ x:CGFloat,_ y:CGFloat) -> CGPoint { view.convert(CGPoint(x:x,y:y),from:page) }
            XCTAssertTrue(session.pointerDown(at:point(80,90))); XCTAssertTrue(session.pointerUp(at:point(80,90)))
            XCTAssertTrue(session.pointerDown(at:point(200,90))); XCTAssertTrue(session.pointerUp(at:point(200,90)))
            XCTAssertTrue(session.pointerDown(at:point(80,170),clickCount:2)); _ = session.pointerUp(at:point(80,170))
            let payload=try XCTUnwrap(SnapshotPayload.clipboard())
            XCTAssertTrue(page.annotations.isEmpty)
            let before=try XCTUnwrap(page.drawbridgeThumbnail(of:CGSize(width:500,height:500),for:.mediaBox).tiffRepresentation)
            let stamp=try XCTUnwrap(session.pasteSnapshot(payload,on:page,center:.zero,inPlace:true))
            let output=source.appendingPathExtension(UUID().uuidString + ".pdf")
            defer { try? FileManager.default.removeItem(at:output) }
            XCTAssertTrue(PDFRectangleWriter.write(document:doc,source:source,destination:output,pageLabels:[:],records:RectangleMarkupRecord.capture(doc)))
            let restored=try XCTUnwrap(PDFDocument(url:output))
            let after=try XCTUnwrap(restored.page(at:0)!.drawbridgeThumbnail(of:CGSize(width:500,height:500),for:.mediaBox).tiffRepresentation)
            let a=try XCTUnwrap(NSBitmapImageRep(data:before)), b=try XCTUnwrap(NSBitmapImageRep(data:after)); var changedPixels=0
            for y in 0..<a.pixelsHigh { for x in 0..<a.pixelsWide {
                let c=a.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!, d=b.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                if abs(c.redComponent-d.redComponent)+abs(c.greenComponent-d.greenComponent)+abs(c.blueComponent-d.blueComponent)>0.1 { changedPixels += 1 }
            } }
            XCTAssertLessThan(changedPixels,1200,"Paste in place must align with captured content, rotation \(rotation)")
            XCTAssertEqual(stamp.bounds.minX,80,accuracy:0.00001); XCTAssertEqual(stamp.bounds.minY,90,accuracy:0.00001)
            XCTAssertEqual(stamp.bounds.width,120,accuracy:0.00001); XCTAssertEqual(stamp.bounds.height,80,accuracy:0.00001)
            session.setBounds(stamp.bounds.offsetBy(dx:35,dy:20),of:stamp,on:page,action:"Move")
            let copied=try XCTUnwrap(SnapshotPayload.read(stamp)); copied.copy()
            let duplicate=try XCTUnwrap(session.pasteSnapshot(SnapshotPayload.clipboard()!,on:page,center:.zero,inPlace:true))
            XCTAssertEqual(duplicate.bounds,stamp.bounds)
            session.tool = .snapshotBox
            XCTAssertTrue(session.pointerDown(at:point(210,210))); XCTAssertTrue(session.pointerUp(at:point(210,210)))
            session.cancelGesture(); XCTAssertEqual(page.annotations.count,2)
        }
    }
    func testLocalArchitecturalSnapshotFiltersSaveReopen() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_FILTER_FIXTURE"] else {
            throw XCTSkip("Provide a local architectural PDF for filtered Snapshot integration testing")
        }
        let source = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: source, options: .mappedIfSafe)
        let doc = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(doc.page(at: 0))
        let box = page.bounds(for: .cropBox)
        let crop = CGRect(x: box.midX - box.width / 8, y: box.midY - box.height / 8, width: box.width / 4, height: box.height / 4)
        let payload = try SnapshotPayload.capture(page: page, points: [
            CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.minY),
            CGPoint(x: crop.maxX, y: crop.maxY), CGPoint(x: crop.minX, y: crop.maxY)
        ])
        let view = MarkupPDFView(); view.document = doc
        let session = view.rectangleMarkup; session.bind(to: doc); session.canEdit = { true }
        let pasted = try XCTUnwrap(session.pasteSnapshot(payload, on: page, center: CGPoint(x: crop.midX, y: crop.midY)))
        let identity = try XCTUnwrap(RectangleMarkupRecord.identity(pasted))
        for filter in SnapshotStyle.Filter.allCases {
            let style = SnapshotStyle(overlay: true, opacity: 0.65, filter: filter, color: [0, 0.5, 1])
            session.styleSelectedSnapshot(style)
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("ArchitecturalFilter-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: output) }
            let start = Date()
            XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(doc)))
            print("Architectural filter", filter.rawValue, "save seconds", Date().timeIntervalSince(start))
            XCTAssertTrue(try Data(contentsOf: output, options: .mappedIfSafe).starts(with: original))
            let reopened = try XCTUnwrap(PDFDocument(url: output))
            XCTAssertEqual(reopened.pageCount, doc.pageCount)
            let saved = try XCTUnwrap(reopened.page(at: 0)?.annotations.first { RectangleMarkupRecord.identity($0) == identity })
            XCTAssertEqual(SnapshotStyle.read(saved), style)
            XCTAssertEqual(SnapshotPayload.read(saved)?.data, payload.data)
        }
    }

    func testLargeFilteredSnapshotSavePreservesOriginalAndReopens() throws {
        _ = NSApplication.shared
        let source = try fixture()
        let output = source.deletingLastPathComponent().appendingPathComponent("LargeFiltered-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let doc = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(doc.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        let payload = try SnapshotPayload.capture(page: page, points: [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)
        ])
        let view = MarkupPDFView(); view.document = doc
        let session = view.rectangleMarkup; session.bind(to: doc); session.canEdit = { true }
        _ = try XCTUnwrap(session.pasteSnapshot(payload, on: page, center: CGPoint(x: box.midX, y: box.midY)))
        let style = SnapshotStyle(filter: .grayscale)
        session.styleSelectedSnapshot(style)
        XCTAssertEqual(SnapshotStyle.read(try XCTUnwrap(session.selected)), style)
        let original = try Data(contentsOf: source)
        XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(doc)))
        guard FileManager.default.fileExists(atPath: output.path) else { return }
        let written = try Data(contentsOf: output)
        XCTAssertTrue(written.starts(with: original))
        XCTAssertGreaterThan(written.count - original.count, 5 * 1024 * 1024, "Exercise the former compressed-payload size ceiling")
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        let saved = try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
        XCTAssertEqual(SnapshotStyle.read(saved), style)
        XCTAssertEqual(SnapshotPayload.read(saved)?.data, payload.data)
        XCTAssertTrue(PDFRectangleWriter.write(document: reopened, source: output, destination: output, pageLabels: [:], records: RectangleMarkupRecord.capture(reopened)))
    }

    func testSnapshotFiltersOverlayOpacitySaveReopenAndUndo() throws {
        _ = NSApplication.shared
        for rotation in [0,90,180,270] {
            let source=try fixture(rotation:rotation); defer { try? FileManager.default.removeItem(at:source) }
            let doc=try XCTUnwrap(PDFDocument(url:source)), page=doc.page(at:0)!, payload=try capture(page,polygon:true)
            let view=MarkupPDFView(); view.document=doc
            let session=view.rectangleMarkup; session.bind(to:doc); session.canEdit={true}; session.undo.groupsByEvent=false
            session.undo.beginUndoGrouping()
            _ = try XCTUnwrap(session.pasteSnapshot(payload,on:page,center:CGPoint(x:250,y:240)))
            session.undo.endUndoGrouping()
            for filter in SnapshotStyle.Filter.allCases {
                let style=SnapshotStyle(overlay:true,opacity:0.55,filter:filter,color:[0,0.65,0.15])
                session.undo.beginUndoGrouping(); session.styleSelectedSnapshot(style); session.undo.endUndoGrouping()
                let selected=try XCTUnwrap(session.selected)
                XCTAssertEqual(SnapshotStyle.read(selected),style); XCTAssertEqual(SnapshotPayload.read(selected)?.data,payload.data)
                let out=source.deletingLastPathComponent().appendingPathComponent("Styled-\(UUID().uuidString).pdf")
                defer { try? FileManager.default.removeItem(at:out) }
                XCTAssertTrue(PDFRectangleWriter.write(document:doc,source:source,destination:out,pageLabels:[:],records:RectangleMarkupRecord.capture(doc)))
                let saved=try XCTUnwrap(PDFDocument(url:out)), savedStamp=try XCTUnwrap(saved.page(at:0)!.annotations.first)
                XCTAssertEqual(SnapshotStyle.read(savedStamp),style); XCTAssertEqual(SnapshotPayload.read(savedStamp)?.data,payload.data)
                let a=try XCTUnwrap(NSBitmapImageRep(data:page.drawbridgeThumbnail(of:CGSize(width:500,height:500),for:.mediaBox).tiffRepresentation!))
                let b=try XCTUnwrap(NSBitmapImageRep(data:saved.page(at:0)!.drawbridgeThumbnail(of:CGSize(width:500,height:500),for:.mediaBox).tiffRepresentation!))
                var differences=0
                for y in 0..<a.pixelsHigh { for x in 0..<a.pixelsWide {
                    let c=a.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!, d=b.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                    if abs(c.redComponent-d.redComponent)+abs(c.greenComponent-d.greenComponent)+abs(c.blueComponent-d.blueComponent)>0.1 { differences += 1 }
                } }
                XCTAssertLessThan(differences,1200,"Live and saved filter match at rotation \(rotation), \(filter)")
                session.undo.undo(); XCTAssertNotEqual(SnapshotStyle.read(session.selected!),style)
                session.undo.redo(); XCTAssertEqual(SnapshotStyle.read(session.selected!),style)
            }
            session.undo.beginUndoGrouping(); session.styleSelectedSnapshot(SnapshotStyle()); session.undo.endUndoGrouping()
            XCTAssertEqual(SnapshotPayload.read(session.selected!)?.data,payload.data)
            XCTAssertEqual(try SnapshotFilterRenderer.filtered(payload.data,style:SnapshotStyle()),payload.data)
        }
    }

    func testChangeColorUsesChosenColorForDarkLineworkAndCanRestoreOriginal() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url:source)), payload = try capture(document.page(at:0)!)
        for color in [[0.2,0.7,0.4], [0.7,0.2,0.85], [0.0,0.0,0.0]] {
            let filtered = try SnapshotFilterRenderer.filtered(payload.data, style: SnapshotStyle(filter:.colorize, color:color))
            let page = try XCTUnwrap(SnapshotPayload(data:filtered).page)
            XCTAssertEqual(page.getBoxRect(.mediaBox).size, payload.size)
            let pixels = try raster(page, size:payload.size!)
            var chosenColorPixels = 0, whitePixels = 0
            for i in stride(from:0,to:pixels.count,by:4) where pixels[i+3] > 250 {
                if (0..<3).allSatisfy({ abs(Double(pixels[i+$0])/255-color[$0]) < 0.04 }) { chosenColorPixels += 1 }
                if (0..<3).allSatisfy({ pixels[i+$0] > 250 }) { whitePixels += 1 }
            }
            XCTAssertGreaterThan(chosenColorPixels, 20); XCTAssertGreaterThan(whitePixels, 1000)
            XCTAssertEqual(try SnapshotFilterRenderer.filtered(payload.data,style:SnapshotStyle()), payload.data)
        }
    }

    func testOverlayRevealsUnderlyingDrawingAndFiltersChangePixels() throws {
        let source=try fixture(); defer { try? FileManager.default.removeItem(at:source) }
        let doc=try XCTUnwrap(PDFDocument(url:source)), page=doc.page(at:0)!
        let payload=try SnapshotPayload.capture(page:page,points:[CGPoint(x:220,y:220),CGPoint(x:240,y:220),CGPoint(x:240,y:240),CGPoint(x:220,y:240)])
        let view=MarkupPDFView(); view.document=doc; let session=view.rectangleMarkup; session.bind(to:doc); session.canEdit={true}
        func pixels(_ page:PDFPage) throws -> Data { try XCTUnwrap(page.drawbridgeThumbnail(of:CGSize(width:500,height:400),for:.mediaBox).tiffRepresentation) }
        func savedPixels() throws -> Data {
            let output=source.appendingPathExtension(UUID().uuidString + ".pdf")
            defer { try? FileManager.default.removeItem(at:output) }
            XCTAssertTrue(PDFRectangleWriter.write(document:doc,source:source,destination:output,pageLabels:[:],records:RectangleMarkupRecord.capture(doc)))
            let saved=try XCTUnwrap(PDFDocument(url:output))
            return try withExtendedLifetime(saved) { try pixels(saved.page(at:0)!) }
        }
        let before=try pixels(page)
        _ = try XCTUnwrap(session.pasteSnapshot(payload,on:page,center:CGPoint(x:140,y:110)))
        func difference(_ data:Data) throws -> Int {
            let a=try XCTUnwrap(NSBitmapImageRep(data:before)), b=try XCTUnwrap(NSBitmapImageRep(data:data)); var count=0
            for y in 0..<a.pixelsHigh { for x in 0..<a.pixelsWide {
                let c=a.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!, d=b.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                if abs(c.redComponent-d.redComponent)+abs(c.greenComponent-d.greenComponent)+abs(c.blueComponent-d.blueComponent)>0.1 { count += 1 }
            } }
            return count
        }
        let normalDifference=try difference(savedPixels()); XCTAssertGreaterThan(normalDifference,100,"Normal snapshot must cover the blue drawing")
        session.styleSelectedSnapshot(SnapshotStyle(overlay:true))
        let overlayDifference=try difference(savedPixels())
        print("Overlay pixel differences",normalDifference,overlayDifference)
        XCTAssertLessThan(overlayDifference,20,"White overlay must reveal the original blue drawing beneath")
        let colorful=try capture(page)
        let original=try raster(colorful.page!,size:colorful.size!)
        for filter in [SnapshotStyle.Filter.grayscale,.colorize,.invert] {
            let filtered=try SnapshotFilterRenderer.filtered(colorful.data,style:SnapshotStyle(filter:filter))
            XCTAssertNotEqual(try raster(SnapshotPayload(data:filtered).page!,size:colorful.size!),original)
        }
    }

    func testLocalPhotoOpacity() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_OPACITY_FIXTURE"] else { throw XCTSkip("Local photo fixture") }
        let doc = try XCTUnwrap(PDFDocument(url:URL(fileURLWithPath:path))), page=doc.page(at:0)!
        let payload: SnapshotPayload
        if let stamp = page.annotations.first(where: { SnapshotPayload.read($0)?.size?.width ?? 0 > 600 }), let saved = SnapshotPayload.read(stamp) {
            payload = saved
        } else {
            let crop = page.bounds(for: .cropBox).insetBy(dx: 400, dy: 400)
            payload = try SnapshotPayload.capture(page: page, points: [CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.maxY), CGPoint(x: crop.minX, y: crop.maxY)])
        }
        let white = PDFPage(); white.setBounds(CGRect(x:0,y:0,width:800,height:800),for:.mediaBox)
        let testDoc=PDFDocument(); testDoc.insert(white,at:0)
        let view=MarkupPDFView(); view.document=testDoc
        let session=view.rectangleMarkup; session.bind(to:testDoc); session.canEdit={true}
        _ = try session.pasteSnapshot(payload,on:white,center:CGPoint(x:400,y:400))
        func darkness() throws -> Double {
            let rep=try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(white.drawbridgeThumbnail(of:CGSize(width:400,height:400),for:.mediaBox).tiffRepresentation)))
            var total=0.0
            for y in 100..<300 { for x in 100..<300 {
                let c=rep.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                total += 3-Double(c.redComponent+c.greenComponent+c.blueComponent)
            } }
            return total
        }
        let before=try darkness(); XCTAssertGreaterThan(before, 100); session.styleSelectedSnapshot(SnapshotStyle(opacity:0.28)); let after=try darkness()
        XCTAssertLessThan(after,before*0.4)
    }

    func testSnapshotOpacityChangesRenderedAppearance() throws {
        _ = NSApplication.shared
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let doc = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(doc.page(at: 0))
        let payload = try capture(page)
        let view = MarkupPDFView(); view.document = doc
        let session = view.rectangleMarkup; session.bind(to: doc); session.canEdit = { true }
        session.undo.groupsByEvent = false
        session.undo.beginUndoGrouping()
        let initial = try XCTUnwrap(session.pasteSnapshot(payload, on: page, center: CGPoint(x: 350, y: 250)))
        session.undo.endUndoGrouping()
        func darkness() throws -> Double {
            let image = page.drawbridgeThumbnail(of: CGSize(width: 500, height: 400), for: .mediaBox)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            // The pasted capture is on otherwise white paper.
            var total = 0.0
            for y in 110..<190 { for x in 260..<380 {
                let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                total += 3 - Double(color.redComponent + color.greenComponent + color.blueComponent)
            } }
            return total
        }
        let opaque = try darkness()
        session.undo.beginUndoGrouping()
        session.styleSelectedSnapshot(SnapshotStyle(opacity: 0.28))
        session.undo.endUndoGrouping()
        let faded = try darkness()
        XCTAssertGreaterThan(opaque, 100)
        XCTAssertLessThan(faded, opaque * 0.4)
        XCTAssertGreaterThan(faded, opaque * 0.15)
        XCTAssertFalse(initial.shouldDisplay)
        let fadedAnnotation = try XCTUnwrap(session.selected)
        XCTAssertTrue(fadedAnnotation.shouldDisplay)
        session.undo.undo()
        XCTAssertTrue(initial.shouldDisplay)
        XCTAssertFalse(fadedAnnotation.shouldDisplay)
        XCTAssertEqual(try darkness(), opaque, accuracy: 1)
        session.undo.redo()
        XCTAssertFalse(initial.shouldDisplay)
        XCTAssertEqual(try darkness(), faded, accuracy: 1)
        session.undo.beginUndoGrouping()
        session.deleteSelected()
        session.undo.endUndoGrouping()
        XCTAssertFalse(fadedAnnotation.shouldDisplay)
        XCTAssertLessThan(try darkness(), 1)
        session.undo.undo()
        XCTAssertTrue(fadedAnnotation.shouldDisplay)
        XCTAssertEqual(try darkness(), faded, accuracy: 1)
    }

    func testPasteInPlaceKeyMonitorPlacesCaptureAtSourceCoordinates() throws {
        _ = NSApplication.shared
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        let controller = MainViewController(); _ = controller.view; controller.openDocumentURL = source
        let window = SnapshotKeyWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.pdfView.setMarkupDocument(document); controller.pdfView.go(to: page)
        try capture(page).copy()
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "V", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        window.makeFirstResponder(controller.pdfView)
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertNil(controller.routeKeyDownEvent(event))
        let selected = try XCTUnwrap(controller.pdfView.rectangleMarkup.selected)
        XCTAssertEqual(selected.bounds.minX, 80, accuracy: 0.00001)
        XCTAssertEqual(selected.bounds.minY, 90, accuracy: 0.00001)
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertNil(controller.routeKeyDownEvent(event))
        XCTAssertEqual(page.annotations.count, 2)
        XCTAssertEqual(controller.pdfView.rectangleMarkup.selected?.bounds, selected.bounds)
        let text = NSTextField(frame: CGRect(x: 0, y: 0, width: 100, height: 24))
        controller.view.addSubview(text)
        window.makeFirstResponder(text)
        XCTAssertNotNil(controller.routeKeyDownEvent(event))
        XCTAssertEqual(page.annotations.count, 2)
    }

    func testPasteInPlaceCommandRequiresCoordinatesAndShowsSnapshotInspector() throws {
        _ = NSApplication.shared
        let source=try fixture(); defer { try? FileManager.default.removeItem(at:source) }
        let document=try XCTUnwrap(PDFDocument(url:source)), page=document.page(at:0)!
        let controller=MainViewController(); _ = controller.view; controller.openDocumentURL=source
        controller.pdfView.setMarkupDocument(document); controller.pdfView.go(to:page)
        let item=NSMenuItem(title:"Paste in Place",action:#selector(MainViewController.commandPasteInPlace(_:)),keyEquivalent:"v")
        NSPasteboard.general.clearContents(); XCTAssertFalse(controller.validateMenuItem(item))
        let payload=try capture(page); SnapshotPayload(data:payload.data).copy()
        XCTAssertFalse(controller.validateMenuItem(item))
        payload.copy(); XCTAssertTrue(controller.validateMenuItem(item)); controller.commandPasteInPlace(nil)
        let selected=try XCTUnwrap(controller.pdfView.rectangleMarkup.selected)
        XCTAssertEqual(selected.bounds.minX,80,accuracy:0.00001); XCTAssertEqual(selected.bounds.minY,90,accuracy:0.00001)
        let inspector=controller.rectangleToolbar.propertiesController; inspector.refresh()
        XCTAssertFalse(inspector.snapshotFilter.isHiddenOrHasHiddenAncestor); XCTAssertTrue(inspector.snapshotFilter.isEnabled)
        inspector.snapshotFilter.selectItem(withTitle:"Grayscale"); inspector.changeSnapshot(inspector.snapshotFilter)
        XCTAssertEqual(SnapshotStyle.read(controller.pdfView.rectangleMarkup.selected!).filter,.grayscale)
        XCTAssertTrue(inspector.snapshotColor.isEnabled)
        controller.pdfView.rectangleMarkup.onSnapshotError = { XCTFail("Snapshot color failed: \($0)") }
        inspector.snapshotColor.color = NSColor(deviceRed: 0.2, green: 0.7, blue: 0.4, alpha: 1)
        inspector.changeSnapshot(inspector.snapshotColor)
        let recolored = SnapshotStyle.read(controller.pdfView.rectangleMarkup.selected!)
        XCTAssertEqual(recolored.filter, .colorize)
        XCTAssertEqual(recolored.color[0], 0.2, accuracy: 0.0001)
        XCTAssertEqual(recolored.color[1], 0.7, accuracy: 0.0001)
        XCTAssertEqual(recolored.color[2], 0.4, accuracy: 0.0001)
        XCTAssertTrue(inspector.stroke.isHiddenOrHasHiddenAncestor)
    }

}
