import AppKit
import PDFKit
import CoreText
import XCTest
@testable import Drawbridge

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
            let live = doc.page(at:index)!.thumbnail(of:CGSize(width:500,height:500),for:.mediaBox)
            let savedDoc = PDFDocument(url:output)!
            let saved = savedDoc.page(at:index)!.thumbnail(of:CGSize(width:500,height:500),for:.mediaBox)
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
            let expected = try XCTUnwrap(NSBitmapImageRep(data:p.thumbnail(of:CGSize(width:500,height:500),for:.mediaBox).tiffRepresentation!))
            let actual = try XCTUnwrap(NSBitmapImageRep(data:raw.thumbnail(of:CGSize(width:500,height:500),for:.mediaBox).tiffRepresentation!))
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
        XCTAssertLessThan(elapsed,5)
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
            let before=try XCTUnwrap(page.thumbnail(of:CGSize(width:500,height:500),for:.mediaBox).tiffRepresentation)
            let stamp=try XCTUnwrap(session.pasteSnapshot(payload,on:page,center:.zero,inPlace:true))
            let output=source.appendingPathExtension(UUID().uuidString + ".pdf")
            defer { try? FileManager.default.removeItem(at:output) }
            XCTAssertTrue(PDFRectangleWriter.write(document:doc,source:source,destination:output,pageLabels:[:],records:RectangleMarkupRecord.capture(doc)))
            let restored=try XCTUnwrap(PDFDocument(url:output))
            let after=try XCTUnwrap(restored.page(at:0)!.thumbnail(of:CGSize(width:500,height:500),for:.mediaBox).tiffRepresentation)
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
                let a=try XCTUnwrap(NSBitmapImageRep(data:page.thumbnail(of:CGSize(width:500,height:500),for:.mediaBox).tiffRepresentation!))
                let b=try XCTUnwrap(NSBitmapImageRep(data:saved.page(at:0)!.thumbnail(of:CGSize(width:500,height:500),for:.mediaBox).tiffRepresentation!))
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

    func testOverlayRevealsUnderlyingDrawingAndFiltersChangePixels() throws {
        let source=try fixture(); defer { try? FileManager.default.removeItem(at:source) }
        let doc=try XCTUnwrap(PDFDocument(url:source)), page=doc.page(at:0)!
        let payload=try SnapshotPayload.capture(page:page,points:[CGPoint(x:220,y:220),CGPoint(x:240,y:220),CGPoint(x:240,y:240),CGPoint(x:220,y:240)])
        let view=MarkupPDFView(); view.document=doc; let session=view.rectangleMarkup; session.bind(to:doc); session.canEdit={true}
        func pixels(_ page:PDFPage) throws -> Data { try XCTUnwrap(page.thumbnail(of:CGSize(width:500,height:400),for:.mediaBox).tiffRepresentation) }
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
        XCTAssertTrue(inspector.stroke.isHiddenOrHasHiddenAncestor)
    }

}
