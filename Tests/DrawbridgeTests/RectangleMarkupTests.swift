import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class RectangleMarkupTests: XCTestCase {
    private func fixture(rotation: Int, signed: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RectangleBase-\(UUID().uuidString).pdf")
        let drawing = "q 0.2 0.4 0.7 rg 110 90 200 100 re f Q\nBT /F1 18 Tf 80 260 Td (ORIGINAL CONTENT) Tj ET\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /P (A1.00) >>] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 610 420] /CropBox [40 50 560 380] /Rotate \(rotation) /Resources << /Font << /F1 6 0 R >> >> /Contents 4 0 R /Annots [5 0 R << /Type /Annot /Subtype /Square /Rect [410 100 450 140] /C [0 0 0] /F 4 /Contents (Imported CAD box) >>] >>",
            "<< /Length \(drawing.utf8.count) >>\nstream\n\(drawing)endstream",
            signed ? "<< /FT /Sig /Type /Annot /Subtype /Widget /Rect [50 60 70 80] >>" : "<< /Type /Annot /Subtype /Link /Rect [50 60 70 80] /Border [0 0 0] /A << /S /GoTo /D [3 0 R /Fit] >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        var data = Data("%PDF-1.7\n".utf8); var offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = data.count; data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try data.write(to: url); return url
    }

    func testAnnotationOnlySavePreservesGeometryTextLinksAndImportedDirectAnnotations() throws {
        guard PDFTKBookmarkWriter.executableURL() != nil else { throw XCTSkip("qpdf required") }
        for rotation in [0,90,180,270] {
            let source = try fixture(rotation: rotation)
            defer { try? FileManager.default.removeItem(at: source) }
            let original = try Data(contentsOf: source)
            let doc = try XCTUnwrap(PDFDocument(url: source)); let page = try XCTUnwrap(doc.page(at:0))
            let session = RectangleMarkupController(); session.bind(to:doc)
            let rect = try XCTUnwrap(session.create(on:page,bounds:CGRect(x:350,y:210,width:130,height:90)))
            let records = RectangleMarkupRecord.capture(doc)
            XCTAssertEqual(records.count,1)
            let output = source.deletingLastPathComponent().appendingPathComponent("RectangleSaved-\(rotation)-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at:output) }
            XCTAssertTrue(MainViewController.writePDFDocument(doc,to:output,pageLabels:[0:"A1.00"],navigationSourceURL:source,rectangleRecords:records))
            XCTAssertEqual(try Data(contentsOf:source),original)
            let reopened = try XCTUnwrap(PDFDocument(url:output)); let writtenPage = try XCTUnwrap(reopened.page(at:0))
            XCTAssertEqual(writtenPage.rotation,rotation)
            XCTAssertEqual(writtenPage.bounds(for:.mediaBox),page.bounds(for:.mediaBox))
            XCTAssertEqual(writtenPage.bounds(for:.cropBox),page.bounds(for:.cropBox))
            XCTAssertEqual(reopened.string,doc.string)
            XCTAssertEqual(writtenPage.annotations.filter { $0.type == "Link" }.count,1)
            XCTAssertEqual(writtenPage.annotations.filter { $0.contents == "Imported CAD box" }.count,1)
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened),records)
            let firstSize = try Data(contentsOf:output).count
            // Repeated saves replace our annotations, never accumulate another rectangle.
            for _ in 0..<3 { XCTAssertTrue(MainViewController.writePDFDocument(reopened,to:output,pageLabels:[0:"A1.00"],navigationSourceURL:output,rectangleRecords:records)) }
            XCTAssertLessThanOrEqual(try Data(contentsOf:output).count,firstSize + 2000)
            let again = try XCTUnwrap(PDFDocument(url:output)); XCTAssertEqual(RectangleMarkupRecord.capture(again).count,1)
            // Deleting the last owned rectangle must still use annotation-only persistence.
            XCTAssertTrue(MainViewController.writePDFDocument(again,to:output,pageLabels:[0:"A1.00"],navigationSourceURL:output,rectangleRecords:[]))
            let deleted = try XCTUnwrap(PDFDocument(url:output))
            XCTAssertTrue(RectangleMarkupRecord.capture(deleted).isEmpty)
            XCTAssertEqual(deleted.page(at:0)?.annotations.count,2)
            XCTAssertEqual(rect.bounds,CGRect(x:350,y:210,width:130,height:90))
            if let directory = ProcessInfo.processInfo.environment["DRAWBRIDGE_RECTANGLE_QA"] {
                let folder = URL(fileURLWithPath:directory); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try original.write(to:folder.appendingPathComponent("before-\(rotation).pdf"))
                XCTAssertTrue(MainViewController.writePDFDocument(doc,to:folder.appendingPathComponent("after-\(rotation).pdf"),pageLabels:[0:"A1.00"],navigationSourceURL:source,rectangleRecords:records))
            }
        }
    }

    func testAllShapesSaveAtEveryRotationWithEndpointUndo() throws {
        guard PDFTKBookmarkWriter.executableURL() != nil else { throw XCTSkip("qpdf required") }
        for rotation in [0,90,180,270] {
            let source = try fixture(rotation:rotation)
            defer { try? FileManager.default.removeItem(at:source) }
            let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
            let session = RectangleMarkupController(); session.bind(to:doc); session.undo.groupsByEvent = false
            func transaction(_ body: () -> Void) { session.undo.beginUndoGrouping(); body(); session.undo.endUndoGrouping() }
            var arrow: PDFAnnotation?
            transaction {
                _ = session.create(on:page,bounds:CGRect(x:330,y:220,width:140,height:80),kind:.ellipse)
                let a = CGPoint(x:90,y:200), b = CGPoint(x:250,y:200)
                _ = session.create(on:page,bounds:RectangleMarkupController.lineBounds(a,b,width:2),kind:.line,endpoints:(a,b))
                let c = CGPoint(x:280,y:320), d = CGPoint(x:200,y:100)
                arrow = session.create(on:page,bounds:RectangleMarkupController.lineBounds(c,d,width:2),kind:.arrow,endpoints:(c,d))
            }
            let annotation = try XCTUnwrap(arrow), initial = RectangleMarkupRecord.capture(doc)
            let a = CGPoint(x:320,y:320), b = CGPoint(x:220,y:100)
            transaction { session.setGeometry(RectangleMarkupController.lineBounds(a,b,width:2),endpoints:(a,b),of:annotation,on:page,action:"Move Arrow") }
            session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.capture(doc),initial)
            session.undo.redo(); XCTAssertEqual(RectangleMarkupRecord.capture(doc).last?.start,a)
            transaction { session.styleSelected(color:.blue,width:4) }
            session.undo.undo(); XCTAssertEqual(annotation.border?.lineWidth,2)
            let records = RectangleMarkupRecord.capture(doc)
            XCTAssertTrue(records.allSatisfy(\.isValid))
            let output = source.deletingLastPathComponent().appendingPathComponent("Shapes-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at:output) }
            XCTAssertTrue(PDFRectangleWriter.write(document:doc,source:source,destination:output,pageLabels:[:],records:records))
            let reopened = try XCTUnwrap(PDFDocument(url:output)), written = try XCTUnwrap(reopened.page(at:0))
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened),records)
            XCTAssertEqual(written.rotation,rotation); XCTAssertEqual(written.bounds(for:.cropBox),page.bounds(for:.cropBox))
            XCTAssertEqual(reopened.string,doc.string); XCTAssertEqual(written.annotations.filter { !RectangleMarkupRecord.owns($0) }.count,2)
            if let directory = ProcessInfo.processInfo.environment["DRAWBRIDGE_SHAPE_QA"] {
                let folder = URL(fileURLWithPath:directory); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try Data(contentsOf:source).write(to:folder.appendingPathComponent("before-\(rotation).pdf"))
                try Data(contentsOf:output).write(to:folder.appendingPathComponent("after-\(rotation).pdf"))
            }
            XCTAssertTrue(PDFRectangleWriter.write(document:reopened,source:output,destination:output,pageLabels:[:],records:[]))
            XCTAssertEqual(PDFDocument(url:output)?.page(at:0)?.annotations.count,2)
        }
    }

    func testBluebeamToolShortcutsRespectModifiersAndBusyState() throws {
        _ = NSApplication.shared
        func key(_ text: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:0)!
        }
        let session = RectangleMarkupController()
        for (text,flags,tool) in [("e",NSEvent.ModifierFlags(),RectangleMarkupController.Tool.ellipse),("r",[],.rectangle),("l",[],.line),("N",[.shift],.polyline),("P",[.shift],.polygon)] {
            XCTAssertTrue(session.handleToolShortcut(key(text,flags))); XCTAssertEqual(session.tool,tool)
        }
        for event in [key("n"),key("l",[.command]),key("r",[.option]),key("e",[.shift]),key("n",[.shift,.control])] { XCTAssertFalse(session.handleToolShortcut(event)) }
        session.canEdit = { false }; XCTAssertFalse(session.handleToolShortcut(key("e"))); XCTAssertEqual(session.tool,.polygon)
    }

    func testPolylineSaveMoveResizeUndoAndImportedContentAtEveryRotation() throws {
        guard PDFTKBookmarkWriter.executableURL() != nil else { throw XCTSkip("qpdf required") }
        for rotation in [0,90,180,270] {
            let source = try fixture(rotation:rotation); defer { try? FileManager.default.removeItem(at:source) }
            let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
            let session = RectangleMarkupController(); session.bind(to:doc); session.undo.groupsByEvent = false
            func transaction(_ body: () -> Void) { session.undo.beginUndoGrouping(); body(); session.undo.endUndoGrouping() }
            var annotation: PDFAnnotation?
            let points = [CGPoint(x:100,y:100),CGPoint(x:150,y:210),CGPoint(x:280,y:180),CGPoint(x:380,y:280)]
            transaction { annotation = session.createPolyline(on:page,points:points) }
            let polyline = try XCTUnwrap(annotation), initial = RectangleMarkupRecord.capture(doc)
            XCTAssertEqual(initial.first?.vertices,points); XCTAssertEqual(initial.first?.kind,.polyline)
            transaction { session.setBounds(polyline.bounds.offsetBy(dx:10,dy:20),of:polyline,on:page,action:"Move Polyline") }
            XCTAssertEqual(RectangleMarkupRecord.vertices(polyline),points.map { CGPoint(x:$0.x+10,y:$0.y+20) })
            session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.capture(doc),initial)
            transaction { session.setBounds(polyline.bounds.insetBy(dx:-8,dy:-8),of:polyline,on:page,action:"Resize Polyline") }
            session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.capture(doc),initial)
            transaction { session.styleSelected(color:.blue,width:4) }
            let records = RectangleMarkupRecord.capture(doc)
            let output = source.deletingLastPathComponent().appendingPathComponent("Polyline-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at:output) }
            XCTAssertTrue(PDFRectangleWriter.write(document:doc,source:source,destination:output,pageLabels:[:],records:records))
            let reopened = try XCTUnwrap(PDFDocument(url:output))
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened),records)
            XCTAssertEqual(reopened.page(at:0)?.rotation,rotation); XCTAssertEqual(reopened.string,doc.string)
            XCTAssertEqual(reopened.page(at:0)?.annotations.filter { !RectangleMarkupRecord.owns($0) }.count,2)
            if let root = ProcessInfo.processInfo.environment["DRAWBRIDGE_POLYLINE_QA"] {
                let folder = URL(fileURLWithPath:root); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try Data(contentsOf:source).write(to:folder.appendingPathComponent("before-\(rotation).pdf"))
                try Data(contentsOf:output).write(to:folder.appendingPathComponent("after-\(rotation).pdf"))
            }
            transaction { session.deleteSelected() }; session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.capture(doc),records)
            XCTAssertNil(session.createPolyline(on:page,points:[CGPoint(x:10,y:20)]))
        }
    }

    func testInlineTextCreationEditingCancellationAndDocumentSwitch() throws {
        let source = try fixture(rotation:0); defer { try? FileManager.default.removeItem(at:source) }
        let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
        let view = PDFView(frame:CGRect(x:0,y:0,width:800,height:600)); view.document = doc
        let session = RectangleMarkupController(); session.install(on:view); session.bind(to:doc)
        session.beginTextEditing(on:page,bounds:CGRect(x:140,y:140,width:180,height:80))
        let editor = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
        editor.string = "erlN\nInline text"; session.finishTextEditing()
        XCTAssertEqual(RectangleMarkupRecord.capture(doc).first?.text,"erlN\nInline text")
        let annotation = try XCTUnwrap(page.annotations.first(where:RectangleMarkupRecord.owns))
        session.beginTextEditing(on:page,bounds:annotation.bounds,annotation:annotation)
        XCTAssertFalse(annotation.shouldDisplay)
        let edit = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
        edit.string = "Cancelled"; session.finishTextEditing(cancel:true)
        XCTAssertTrue(annotation.shouldDisplay); XCTAssertEqual(annotation.contents,"erlN\nInline text")
        session.beginTextEditing(on:page,bounds:annotation.bounds,annotation:annotation)
        let last = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
        last.string = "Committed before switching"
        session.bind(to:nil)
        XCTAssertEqual(annotation.contents,"Committed before switching"); XCTAssertTrue(annotation.shouldDisplay)
        XCTAssertFalse(session.isEditingText)
        XCTAssertEqual(doc.string,"ORIGINAL CONTENT")
    }

    func testPathSelectionAndNodeEditingAtEveryRotation() throws {
        for rotation in [0,90,180,270] {
            let source = try fixture(rotation:rotation); defer { try? FileManager.default.removeItem(at:source) }
            let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
            let session = RectangleMarkupController(); session.bind(to:doc)
            session.undo.groupsByEvent = false
            let points = [CGPoint(x:140,y:140),CGPoint(x:220,y:260),CGPoint(x:300,y:140)]
            session.undo.beginUndoGrouping()
            let polygon = try XCTUnwrap(session.createPolyline(on:page,points:points,closed:true))
            session.undo.endUndoGrouping()
            XCTAssertFalse(RectangleMarkupController.hitTest(polygon,at:CGPoint(x:145,y:250),tolerance:2),"Empty bounding-box space must not select")
            XCTAssertTrue(RectangleMarkupController.hitTest(polygon,at:CGPoint(x:220,y:180),tolerance:2))
            session.undo.beginUndoGrouping(); session.fillSelected(nil); session.undo.endUndoGrouping()
            XCTAssertFalse(RectangleMarkupController.hitTest(polygon,at:CGPoint(x:220,y:180),tolerance:2),"Unfilled interior must not select")
            XCTAssertTrue(RectangleMarkupController.hitTest(polygon,at:CGPoint(x:180,y:200),tolerance:2))
            session.undo.removeAllActions()
            let oldBounds = polygon.bounds
            let target = CGPoint(x:240,y:270)
            session.undo.beginUndoGrouping()
            var edited = points; edited[1] = target
            session.setVertexPositions(edited,of:polygon,on:page)
            session.undo.endUndoGrouping()
            for (actual,expected) in zip(RectangleMarkupRecord.vertices(polygon),edited) {
                XCTAssertEqual(actual.x,expected.x,accuracy:0.001); XCTAssertEqual(actual.y,expected.y,accuracy:0.001)
            }
            session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.vertices(polygon),points); XCTAssertEqual(polygon.bounds,oldBounds)
            session.undo.redo()
            session.undo.beginUndoGrouping()
            let line = try XCTUnwrap(session.createPolyline(on:page,points:points))
            session.undo.endUndoGrouping()
            XCTAssertFalse(RectangleMarkupController.hitTest(line,at:CGPoint(x:220,y:140),tolerance:2),"Open path has no closing edge")
            let records = RectangleMarkupRecord.capture(doc)
            let output = source.deletingLastPathComponent().appendingPathComponent("Nodes-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at:output) }
            XCTAssertTrue(PDFRectangleWriter.write(document:doc,source:source,destination:output,pageLabels:[:],records:records))
            let reopened = try XCTUnwrap(PDFDocument(url:output))
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened),records)
            XCTAssertEqual(reopened.page(at:0)?.rotation,rotation)
            XCTAssertEqual(reopened.page(at:0)?.bounds(for:.cropBox),page.bounds(for:.cropBox))
            if let root = ProcessInfo.processInfo.environment["DRAWBRIDGE_NODE_QA"] {
                let folder = URL(fileURLWithPath:root); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try Data(contentsOf:source).write(to:folder.appendingPathComponent("before-\(rotation).pdf"))
                try Data(contentsOf:output).write(to:folder.appendingPathComponent("after-\(rotation).pdf"))
            }
        }
    }

    func testPolygonDrawUsesCropOriginWithoutMovingBasePage() throws {
        let source = try fixture(rotation:0); defer { try? FileManager.default.removeItem(at:source) }
        let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
        let session = RectangleMarkupController(); session.bind(to:doc); session.fillColor = .blue
        let points = [CGPoint(x:140,y:150),CGPoint(x:200,y:150),CGPoint(x:200,y:210),CGPoint(x:140,y:210)]
        let annotation = try XCTUnwrap(session.createPolyline(on:page,points:points,closed:true))
        let context = try XCTUnwrap(CGContext(data:nil,width:520,height:330,bitsPerComponent:8,bytesPerRow:520*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        annotation.draw(with:.cropBox,in:context)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
        XCTAssertEqual(bytes[((330-1-130)*520+130)*4+2],255,"Fill belongs at page coordinates minus crop origin")
        XCTAssertEqual(bytes[((330-1-190)*520+190)*4+3],0,"Unadjusted coordinates must not receive the polygon")
        XCTAssertEqual(page.bounds(for:.cropBox),CGRect(x:40,y:50,width:520,height:330))
    }

    func testPolygonFillUndoGeometryAndSaveAtEveryRotation() throws {
        guard PDFTKBookmarkWriter.executableURL() != nil else { throw XCTSkip("qpdf required") }
        for rotation in [0,90,180,270] {
            let source = try fixture(rotation:rotation); defer { try? FileManager.default.removeItem(at:source) }
            let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
            let session = RectangleMarkupController(); session.bind(to:doc); session.undo.groupsByEvent = false; session.fillColor = .orange
            func transaction(_ body: () -> Void) { session.undo.beginUndoGrouping(); body(); session.undo.endUndoGrouping() }
            var polygon: PDFAnnotation?
            let points = [CGPoint(x:120,y:100),CGPoint(x:140,y:220),CGPoint(x:300,y:240),CGPoint(x:280,y:120)]
            transaction { polygon = session.createPolyline(on:page,points:points,closed:true) }
            let annotation = try XCTUnwrap(polygon), initial = RectangleMarkupRecord.capture(doc)
            XCTAssertEqual(initial.first?.kind,.polygon); XCTAssertNotNil(initial.first?.fill)
            transaction { session.fillSelected(nil) }; XCTAssertNil(RectangleMarkupRecord.capture(doc).first?.fill)
            session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.capture(doc),initial)
            transaction { session.fillSelected(.blue) }
            transaction { session.setBounds(annotation.bounds.offsetBy(dx:10,dy:20),of:annotation,on:page,action:"Move Polygon") }
            session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.vertices(annotation),points)
            let records = RectangleMarkupRecord.capture(doc)
            XCTAssertEqual(records.first?.fill,[0,0,1])
            let output = source.deletingLastPathComponent().appendingPathComponent("Polygon-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at:output) }
            XCTAssertTrue(PDFRectangleWriter.write(document:doc,source:source,destination:output,pageLabels:[:],records:records))
            let reopened = try XCTUnwrap(PDFDocument(url:output))
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened),records)
            session.bind(to:reopened)
            let loaded = try XCTUnwrap(reopened.page(at:0)?.annotations.first(where:RectangleMarkupRecord.owns))
            XCTAssertTrue(loaded is DrawbridgePolygonAnnotation)
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened),records)
            XCTAssertEqual(reopened.page(at:0)?.rotation,rotation); XCTAssertEqual(reopened.string,doc.string)
            if let root = ProcessInfo.processInfo.environment["DRAWBRIDGE_POLYGON_QA"] {
                let folder = URL(fileURLWithPath:root); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try Data(contentsOf:source).write(to:folder.appendingPathComponent("before-\(rotation).pdf"))
                try Data(contentsOf:output).write(to:folder.appendingPathComponent("after-\(rotation).pdf"))
            }
            XCTAssertNil(session.createPolyline(on:reopened.page(at:0)!,points:Array(points.prefix(2)),closed:true))
            XCTAssertTrue(records.first!.isValid)
            let plain = RectangleMarkupController(); plain.bind(to:doc); plain.undo.groupsByEvent = false
            plain.undo.beginUndoGrouping(); _ = plain.createPolyline(on:page,points:points); plain.undo.endUndoGrouping()
            XCTAssertNil(RectangleMarkupRecord.capture(doc).last?.fill,"Polylines must remain unfilled")
        }
    }

    func testTextSaveUnicodeMultilineAndEditingAtEveryRotation() throws {
        guard PDFTKBookmarkWriter.executableURL() != nil else { throw XCTSkip("qpdf required") }
        for rotation in [0,90,180,270] {
            let source = try fixture(rotation:rotation); defer { try? FileManager.default.removeItem(at:source) }
            let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
            let session = RectangleMarkupController(); session.bind(to:doc); session.undo.groupsByEvent = false
            session.fontSize = 18
            func transaction(_ body: () -> Void) { session.undo.beginUndoGrouping(); body(); session.undo.endUndoGrouping() }
            var text: PDFAnnotation?
            transaction { text = session.create(on:page,bounds:CGRect(x:310,y:180,width:230,height:170),kind:.text,text:"REVIEW WALL\nCafé — façade\n检查尺寸") }
            let annotation = try XCTUnwrap(text), initial = RectangleMarkupRecord.capture(doc)
            transaction { session.editSelectedText("Revised note\nSecond line",size:24) }
            session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.capture(doc),initial)
            session.undo.redo(); XCTAssertEqual(annotation.contents,"Revised note\nSecond line")
            session.undo.undo()
            transaction { session.styleSelected(color:.blue,width:2) }
            let records = RectangleMarkupRecord.capture(doc)
            XCTAssertEqual(text?.color.alphaComponent,0, "Text boxes must not fill their background")
            XCTAssertEqual(records.first?.kind,.text); XCTAssertEqual(records.first?.blue,1)
            let output = source.deletingLastPathComponent().appendingPathComponent("Text-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at:output) }
            XCTAssertTrue(PDFRectangleWriter.write(document:doc,source:source,destination:output,pageLabels:[:],records:records))
            let reopened = try XCTUnwrap(PDFDocument(url:output))
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened),records)
            XCTAssertEqual(reopened.page(at:0)?.rotation,rotation); XCTAssertEqual(reopened.string,doc.string)
            if let root = ProcessInfo.processInfo.environment["DRAWBRIDGE_TEXT_QA"] {
                let folder = URL(fileURLWithPath:root); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try Data(contentsOf:source).write(to:folder.appendingPathComponent("before-\(rotation).pdf"))
                try Data(contentsOf:output).write(to:folder.appendingPathComponent("after-\(rotation).pdf"))
            }
            transaction { session.deleteSelected() }; session.undo.undo(); XCTAssertEqual(RectangleMarkupRecord.capture(doc),records)
        }
    }

    func testRectangleUndoRedoAndOwnershipIsolation() throws {
        let source = try fixture(rotation:90); defer { try? FileManager.default.removeItem(at:source) }
        let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
        let imported = page.annotations; let originalBounds = imported.map(\.bounds)
        let session = RectangleMarkupController(); session.bind(to:doc)
        session.undo.groupsByEvent = false
        func transaction(_ body: () -> Void) { session.undo.beginUndoGrouping(); body(); session.undo.endUndoGrouping() }
        var rectangle: PDFAnnotation?
        transaction { rectangle = session.create(on:page,bounds:CGRect(x:100,y:150,width:80,height:60)) }
        let annotation = try XCTUnwrap(rectangle)
        XCTAssertTrue(session.hasUnsavedChanges)
        transaction { session.setBounds(CGRect(x:150,y:180,width:110,height:70),of:annotation,on:page,action:"Move Rectangle") }
        session.undo.undo(); XCTAssertEqual(annotation.bounds,CGRect(x:100,y:150,width:80,height:60))
        session.undo.redo(); XCTAssertEqual(annotation.bounds,CGRect(x:150,y:180,width:110,height:70))
        transaction { session.styleSelected(color:.blue,width:4) }
        XCTAssertEqual(annotation.border?.lineWidth,4)
        session.undo.undo(); XCTAssertEqual(annotation.border?.lineWidth,2)
        transaction { session.deleteSelected() }; XCTAssertFalse(page.annotations.contains { $0 === annotation })
        session.undo.undo(); XCTAssertTrue(page.annotations.contains { $0 === annotation })
        XCTAssertEqual(imported.map(\.bounds),originalBounds); XCTAssertEqual(page.rotation,90)
        XCTAssertFalse(imported.contains { RectangleMarkupRecord.owns($0) })
        session.bind(to:nil); XCTAssertFalse(session.undo.canUndo); XCTAssertNil(session.selected)
    }

    func testBlockedWriterLeavesOriginalBytesUntouched() throws {
        let source = try fixture(rotation:270,signed:true); defer { try? FileManager.default.removeItem(at:source) }
        let original = try Data(contentsOf:source); let doc = try XCTUnwrap(PDFDocument(url:source))
        let record = RectangleMarkupRecord(id:RectangleMarkupRecord.prefix + "test",pageIndex:0,bounds:CGRect(x:100,y:100,width:60,height:40),red:1,green:0,blue:0,lineWidth:2)
        XCTAssertFalse(MainViewController.writePDFDocument(doc,to:source,pageLabels:[:],navigationSourceURL:source,rectangleRecords:[record]))
        XCTAssertEqual(try Data(contentsOf:source),original)
        let invalid = RectangleMarkupRecord(id:record.id,pageIndex:0,bounds:CGRect(x:0,y:0,width:0,height:5),red:1,green:0,blue:0,lineWidth:2)
        XCTAssertFalse(PDFRectangleWriter.write(document:doc,source:source,destination:source,pageLabels:[:],records:[invalid]))
        XCTAssertEqual(try Data(contentsOf:source),original)
    }

    func testDeletedLastRectangleStaysDirtyAcrossDocumentSwitch() throws {
        let source = try fixture(rotation:0); defer { try? FileManager.default.removeItem(at:source) }
        let doc = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(doc.page(at:0))
        let session = RectangleMarkupController(); session.bind(to:doc)
        _ = session.create(on:page,bounds:CGRect(x:100,y:100,width:60,height:40))
        session.deleteSelected(); XCTAssertTrue(RectangleMarkupRecord.capture(doc).isEmpty)
        session.bind(to:PDFDocument()); session.bind(to:doc)
        XCTAssertTrue(session.hasUnsavedChanges)
        session.markSaved(at:source); session.bind(to:nil); session.bind(to:doc)
        XCTAssertFalse(session.hasUnsavedChanges)
    }

    func testChangedSourceIsNotOverwritten() throws {
        let source = try fixture(rotation:0); defer { try? FileManager.default.removeItem(at:source) }
        let doc = try XCTUnwrap(PDFDocument(url:source))
        let stamp = try XCTUnwrap(PDFMarkupSourceStamp.read(source))
        var updated = try Data(contentsOf:source); updated.append(Data("\n% external change\n".utf8)); try updated.write(to:source)
        XCTAssertFalse(PDFRectangleWriter.write(document:doc,source:source,destination:source,pageLabels:[:],records:[],expectedSourceStamp:stamp))
        XCTAssertEqual(try Data(contentsOf:source),updated)
    }

    func testArchitecturalCorpusPreservation() throws {
        guard let root = ProcessInfo.processInfo.environment["DRAWBRIDGE_RECTANGLE_CORPUS"] else { throw XCTSkip("Optional architectural corpus") }
        for name in ["architectural-mech", "civil-marked"] {
            let source = URL(fileURLWithPath: root).appendingPathComponent(name + ".pdf")
            let doc = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(doc.page(at: 0))
            let crop = page.bounds(for: .cropBox)
            let record = RectangleMarkupRecord(id: RectangleMarkupRecord.prefix + name, pageIndex: 0, bounds: CGRect(x: crop.midX, y: crop.midY, width: 80, height: 60), red: 1, green: 0, blue: 0, lineWidth: 2)
            let destination = URL(fileURLWithPath: root).appendingPathComponent(name + "-rectangle.pdf")
            let start = Date()
            XCTAssertTrue(PDFRectangleWriter.write(document: doc, source: source, destination: destination, pageLabels: [:], records: [record]))
            print("Rectangle corpus \(name): \(Date().timeIntervalSince(start))s")
            let reopened = try XCTUnwrap(PDFDocument(url: destination))
            XCTAssertEqual(reopened.pageCount, doc.pageCount)
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened), [record])
            for n in 0..<doc.pageCount {
                XCTAssertEqual(reopened.page(at:n)?.rotation, doc.page(at:n)?.rotation)
                XCTAssertEqual(reopened.page(at:n)?.bounds(for:.cropBox), doc.page(at:n)?.bounds(for:.cropBox))
            }
        }
    }

    func testMarkupControlsAreInstalledSeparatelyAndDisabledWithoutPDF() throws {
        _ = NSApplication.shared
        let controller = MainViewController()
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1400,height:900),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.contentViewController = controller; window.toolbar = controller.makeToolbar(); window.layoutIfNeeded()
        let item = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier == .drawbridgeMarkupControls })
        XCTAssertTrue(item.view === controller.rectangleToolbar)
        XCTAssertFalse(controller.rectangleToolbar.rectangleButton.isEnabled)
        XCTAssertFalse(controller.rectangleToolbar.deleteButton.isEnabled)
        XCTAssertFalse(controller.rectangleToolbar.ellipseButton.isEnabled)
        XCTAssertFalse(controller.rectangleToolbar.lineButton.isEnabled)
        XCTAssertFalse(controller.rectangleToolbar.arrowButton.isEnabled)
        XCTAssertFalse(controller.rectangleToolbar.arrangedSubviews.contains { ($0 as? NSTextField)?.stringValue == "Markup" })
        XCTAssertTrue(window.toolbar?.items.contains { $0.itemIdentifier == .drawbridgePrimaryControls } == true)
    }
}
