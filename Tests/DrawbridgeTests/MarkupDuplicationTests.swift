import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class MarkupDuplicationTests: XCTestCase {
    private func setup() -> (MainViewController, PDFPage, NSWindow) {
        _ = NSApplication.shared
        let c = MainViewController(); c.loadViewIfNeeded()
        let d = PDFDocument(), p = PDFPage()
        p.setBounds(CGRect(x: 0, y: 0, width: 600, height: 400), for: .mediaBox)
        d.insert(p, at: 0); c.pdfView.setMarkupDocument(d)
        c.pdfView.rectangleMarkup.canEdit = { true }
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentViewController = c; c.view.layoutSubtreeIfNeeded(); c.pdfView.layoutDocumentView()
        return (c, p, w)
    }
    func testOptionDragDuplicatesOnceWithoutMovingOriginalOrChangingClipboardAndUndoesTogether() throws {
        let (c, p, w) = setup(); defer { w.contentViewController = nil }
        let s = c.pdfView.rectangleMarkup
        let a = try XCTUnwrap(s.create(on: p, bounds: CGRect(x: 60, y: 60, width: 80, height: 50)))
        let b = try XCTUnwrap(s.create(on: p, bounds: CGRect(x: 180, y: 60, width: 80, height: 50)))
        s.setSelectedItems([a,b]); s.undo.groupsByEvent = false; s.undo.removeAllActions()
        let before = NSPasteboard.general.changeCount
        let start = c.pdfView.convert(CGPoint(x: 60, y: 85), from: p)
        let end = c.pdfView.convert(CGPoint(x: 90, y: 105), from: p)
        XCTAssertTrue(s.pointerDown(at: start, modifiers: .option))
        XCTAssertEqual(p.annotations.count, 2)
        XCTAssertTrue(s.pointerDragged(at: end, modifiers: .option))
        XCTAssertTrue(s.pointerDragged(at: end, modifiers: .option))
        XCTAssertTrue(s.pointerUp(at: end, modifiers: .option))
        XCTAssertEqual(p.annotations.count, 4)
        XCTAssertEqual(a.bounds.origin, CGPoint(x: 60, y: 60)); XCTAssertEqual(b.bounds.origin, CGPoint(x: 180, y: 60))
        XCTAssertEqual(s.selectedItems.count, 2)
        XCTAssertFalse(s.selectedItems.contains { $0 === a || $0 === b })
        XCTAssertEqual(Set(p.annotations.compactMap(RectangleMarkupRecord.identity)).count, 4)
        XCTAssertEqual(NSPasteboard.general.changeCount, before)
        s.undo.undo(); XCTAssertEqual(p.annotations.count, 2)
        s.undo.redo(); XCTAssertEqual(p.annotations.count, 4)
    }
    func testOptionClickDoesNotDuplicateAndPlainDragStillMoves() throws {
        let (c,p,w) = setup(); defer { w.contentViewController = nil }
        let s = c.pdfView.rectangleMarkup
        let a = try XCTUnwrap(s.create(on:p,bounds:CGRect(x:60,y:60,width:80,height:50)))
        let start = c.pdfView.convert(CGPoint(x:60,y:85),from:p)
        XCTAssertTrue(s.pointerDown(at:start,modifiers:.option)); XCTAssertTrue(s.pointerUp(at:start,modifiers:.option))
        XCTAssertEqual(p.annotations.count,1)
        XCTAssertTrue(s.pointerDown(at:start)); XCTAssertTrue(s.pointerUp(at:c.pdfView.convert(CGPoint(x:90,y:105),from:p)))
        XCTAssertEqual(p.annotations.count,1); XCTAssertEqual(a.bounds.origin.x,90,accuracy:0.01)
    }
    func testImportedCopySurvivesVerifiedSaveReopenAndEditing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CopiedMarkup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf"), output = root.appendingPathComponent("saved.pdf")
        let d = PDFDocument(), p = PDFPage(); p.setBounds(CGRect(x:0,y:0,width:600,height:400),for:.mediaBox); d.insert(p,at:0)
        let original = PDFAnnotation(bounds:CGRect(x:60,y:60,width:160,height:70),forType:.freeText,withProperties:nil)
        original.contents = "Bold consultant"; original.font = NSFont(name:"Helvetica-Bold",size:13); original.fontColor = .red; original.userName = "Consultant"
        original.setValue("foreign-id",forAnnotationKey:.init(rawValue:"/NM")); p.addAnnotation(original)
        XCTAssertTrue(d.write(to:source)); let sourceBytes = try Data(contentsOf:source)
        let live = try XCTUnwrap(PDFDocument(url:source)), page = try XCTUnwrap(live.page(at:0))
        let sourceAnnotation = try XCTUnwrap(page.annotations.first)
        let record = try XCTUnwrap(MarkupClipboard.capture(sourceAnnotation))
        let copy = try record.clipboardAnnotation(contents:sourceAnnotation.contents); page.addAnnotation(copy)
        var failure: PDFRectangleWriter.SaveFailure?
        XCTAssertTrue(PDFRectangleWriter.write(document:live,source:source,destination:output,pageLabels:[:],records:RectangleMarkupRecord.capture(live),onFailure:{failure=$0}),"Save rejected: \(failure?.stage ?? "unknown")")
        XCTAssertEqual(try Data(contentsOf:source),sourceBytes)
        let reopened = try XCTUnwrap(PDFDocument(url:output)), savedPage = try XCTUnwrap(reopened.page(at:0))
        XCTAssertEqual(savedPage.annotations.count,2)
        let saved = try XCTUnwrap(savedPage.annotations.first(where:RectangleMarkupRecord.owns))
        XCTAssertNotNil(CopiedMarkupPayload.read(saved))
        let rich = ImportedTextContent.read(saved)
        XCTAssertEqual(rich.string,"Bold consultant")
        XCTAssertTrue(NSFontManager.shared.traits(of:try XCTUnwrap(rich.attribute(.font,at:0,effectiveRange:nil) as? NSFont)).contains(.boldFontMask))
        let view = MarkupPDFView(); view.setMarkupDocument(reopened); let session = view.rectangleMarkup; session.canEdit = {true}; session.setSelectedItems([saved])
        session.editSelectedText("Bold consultant reviewed",size:13)
        XCTAssertEqual(session.selected?.contents,"Bold consultant reviewed")
        XCTAssertEqual(ImportedTextContent.read(try XCTUnwrap(session.selected)).string,"Bold consultant reviewed")
        let edited = try XCTUnwrap(session.selected)
        session.setBounds(CGRect(x:60,y:60,width:100,height:110),of:edited,on:savedPage,action:"Resize")
        let second = root.appendingPathComponent("second.pdf")
        XCTAssertTrue(PDFRectangleWriter.write(document:reopened,source:output,destination:second,pageLabels:[:],records:RectangleMarkupRecord.capture(reopened)))
        let twice = try XCTUnwrap(PDFDocument(url:second)?.page(at:0)?.annotations.first(where:RectangleMarkupRecord.owns))
        XCTAssertEqual(twice.bounds,edited.bounds)
        XCTAssertEqual(ImportedTextContent.read(twice).string,"Bold consultant reviewed")
        XCTAssertEqual(CopiedMarkupPayload.read(twice),CopiedMarkupPayload.read(edited))
    }
    func testCopiedShapeEditsSaveAndRepeatWithoutStalePayload() throws {
        let (c,p,w) = setup(); defer { w.contentViewController = nil }
        let s = c.pdfView.rectangleMarkup
        let foreign = PDFAnnotation(bounds: CGRect(x:60,y:60,width:100,height:70), forType:.square, withProperties:nil)
        foreign.color = .red; foreign.interiorColor = .yellow
        let copy = try XCTUnwrap(MarkupClipboard.capture(foreign)).clipboardAnnotation(contents:nil)
        p.addAnnotation(copy); s.setSelectedItems([copy])
        s.styleSelected(color:.blue,width:5); s.fillSelected(.green)
        s.setBounds(CGRect(x:80,y:80,width:130,height:90),of:copy,on:p,action:"Resize")
        let rec = try XCTUnwrap(MarkupClipboard.capture(copy))
        let reconstructed = try rec.clipboardAnnotation(contents:nil)
        XCTAssertEqual(reconstructed.color.usingColorSpace(.deviceRGB)?.blueComponent,1)
        XCTAssertEqual(reconstructed.interiorColor?.usingColorSpace(.deviceRGB)?.greenComponent,1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("source.pdf"), output = root.appendingPathComponent("output.pdf")
        var d = try XCTUnwrap(p.document); XCTAssertTrue(d.write(to:source))
        var input = source
        for _ in 0..<2 {
            XCTAssertTrue(PDFRectangleWriter.write(document:d,source:input,destination:output,pageLabels:[:],records:RectangleMarkupRecord.capture(d)))
            d = try XCTUnwrap(PDFDocument(url:output))
            let reopened = try XCTUnwrap(d.page(at:0)?.annotations.first)
            XCTAssertEqual(reopened.color.usingColorSpace(.deviceRGB)?.blueComponent,1)
            XCTAssertEqual(reopened.interiorColor?.usingColorSpace(.deviceRGB)?.greenComponent,1)
            XCTAssertEqual(reopened.bounds,copy.bounds)
            XCTAssertEqual(CopiedMarkupPayload.read(reopened),CopiedMarkupPayload.read(copy))
            // Save the reopened document against its own source on the repeat.
            input = output
        }
    }
    func testOptionDragKeepsSelectedBodyAheadOfOverlappingTopmost() throws {
        let (c,p,w) = setup(); defer { w.contentViewController = nil }
        let s = c.pdfView.rectangleMarkup
        let a = try XCTUnwrap(s.create(on:p,bounds:CGRect(x:60,y:60,width:100,height:70)))
        a.contents = "selected"
        let b = try XCTUnwrap(s.create(on:p,bounds:a.bounds)); b.contents = "topmost"
        s.setSelectedItems([a])
        let start = c.pdfView.convert(CGPoint(x:60,y:95),from:p)
        let end = c.pdfView.convert(CGPoint(x:90,y:115),from:p)
        XCTAssertTrue(s.pointerDown(at:start,modifiers:.option)); XCTAssertTrue(s.pointerUp(at:end,modifiers:.option))
        XCTAssertEqual(s.selected?.contents,"selected")
    }
    func testUnsupportedImportedCalloutAndLineRejectAtomically() throws {
        let board = NSPasteboard(name:.init(UUID().uuidString)); board.setString("keep",forType:.string)
        let text = PDFAnnotation(bounds:CGRect(x:0,y:0,width:100,height:60),forType:.freeText,withProperties:nil)
        text.contents = "callout"; text.setValue([0,0,20,20,40,20],forAnnotationKey:.init(rawValue:"/CL"))
        XCTAssertFalse(MarkupClipboard.copy([text],to:board)); XCTAssertEqual(board.string(forType:.string),"keep")
        let line = PDFAnnotation(bounds:text.bounds,forType:.line,withProperties:nil); line.endLineStyle = .closedArrow
        XCTAssertFalse(MarkupClipboard.copy([line],to:board)); XCTAssertEqual(board.string(forType:.string),"keep")
    }
    func testCopiedPlainLineUsesEditedEndpointsOnRepeatCopy() throws {
        // Geometry/clipboard regression needs no controller/window lifecycle.
        let document = PDFDocument(), p = PDFPage()
        p.setBounds(CGRect(x:0,y:0,width:600,height:400),for:.mediaBox)
        document.insert(p,at:0)
        let view = MarkupPDFView(); view.setMarkupDocument(document)
        view.rectangleMarkup.canEdit = { true }
        let line = PDFAnnotation(bounds:CGRect(x:60,y:60,width:100,height:70),forType:.line,withProperties:nil)
        line.startPoint = CGPoint(x:5,y:5); line.endPoint = CGPoint(x:95,y:65)
        let initialRecord = try XCTUnwrap(MarkupClipboard.capture(line))
        XCTAssertTrue(initialRecord.isValid)
        XCTAssertEqual(initialRecord.start,CGPoint(x:65,y:65))
        XCTAssertEqual(initialRecord.end,CGPoint(x:155,y:125))
        let copy = try initialRecord.clipboardAnnotation(contents:nil)
        p.addAnnotation(copy)
        let a = CGPoint(x:90,y:100), b = CGPoint(x:190,y:80)
        view.rectangleMarkup.setGeometry(CGRect(x:80,y:70,width:120,height:50),endpoints:(a,b),of:copy,on:p,action:"Edit Line")
        let repeated = try XCTUnwrap(MarkupClipboard.capture(copy)).clipboardAnnotation(contents:nil)
        XCTAssertEqual(repeated.startPoint,CGPoint(x:10,y:30))
        XCTAssertEqual(repeated.endPoint,CGPoint(x:110,y:10))
    }
    func testControllerCopyPasteImportedTextAndOwnedMarkup() throws {
        let (c,p,w) = setup(); defer { w.contentViewController = nil }
        let s = c.pdfView.rectangleMarkup
        let source = PDFAnnotation(bounds:CGRect(x:60,y:60,width:160,height:70),forType:.freeText,withProperties:nil)
        source.contents = "Consultant bold"; source.font = NSFont(name:"Helvetica-Bold",size:13); source.fontColor = .red
        source.userName = "Consultant"; source.setValue("foreign-id",forAnnotationKey:.init(rawValue:"/NM"))
        p.addAnnotation(source); s.setSelectedItems([source]); w.makeFirstResponder(c.pdfView)
        c.commandCopy(nil)
        XCTAssertTrue(MarkupClipboard.canPaste(), "Imported selected markup must reach object clipboard, not PDF text fallback")
        c.commandPasteInPlace(nil)
        XCTAssertEqual(p.annotations.count,2)
        let copy = try XCTUnwrap(s.selectedItems.first)
        XCTAssertFalse(copy === source); XCTAssertEqual(copy.contents,source.contents); XCTAssertEqual(copy.userName,"Consultant")
        XCTAssertEqual(copy.bounds,source.bounds)
        XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(ImportedTextContent.read(copy).attribute(.font,at:0,effectiveRange:nil) as? NSFont)).contains(.boldFontMask))
        XCTAssertEqual(source.value(forAnnotationKey:.init(rawValue:"/NM")) as? String,"foreign-id")
        let own = try XCTUnwrap(s.create(on:p,bounds:CGRect(x:300,y:60,width:80,height:50)))
        s.setSelectedItems([own]); c.commandCopy(nil); c.commandPasteInPlace(nil)
        XCTAssertEqual(p.annotations.count,4); XCTAssertFalse(s.selectedItems.first === own)
    }
}
