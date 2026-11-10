import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Drawbridge

@MainActor private final class ImageFileDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(_ url: URL) { super.init(); draggingPasteboard.writeObjects([url as NSURL]) }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@MainActor final class ImageImportTests: XCTestCase {
    private func fixture(_ body: (MainViewController, NSWindow, URL) throws -> Void) throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = MainViewController()
        let w = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1200,height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentViewController = c
        defer { w.makeFirstResponder(nil); w.contentViewController = nil }
        try body(c,w,dir)
        XCTAssertFalse(w.isVisible)
    }
    private func image(_ dir: URL, type: UTType = .png, orientation: Int = 1, frames: Int = 1) throws -> URL {
        let url = dir.appendingPathComponent("Drawing.\(type.preferredFilenameExtension!)")
        let ctx = try XCTUnwrap(CGContext(data: nil,width: 240,height: 120,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0,y: 0,width: 120,height: 120))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,type.identifier as CFString,frames,nil))
        for _ in 0..<frames { CGImageDestinationAddImage(dest,try XCTUnwrap(ctx.makeImage()),[kCGImagePropertyOrientation: orientation] as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(dest)); return url
    }
    func testOSOpenQueuesImagesAlongsidePDFs() throws {
        try fixture { _,_,dir in
            let url = try image(dir)
            let delegate = AppDelegate()
            delegate.application(NSApplication.shared, open: [url])
            let pending = Mirror(reflecting: delegate).children.first { $0.label == "pendingOpenURLs" }?.value as? [URL]
            XCTAssertEqual(pending,[url])
        }
    }
    func testImageSaveAsRoundTripKeepsOriginalAndRasterAppearance() throws {
        try fixture { c,w,dir in
            let url = try image(dir); let original = try Data(contentsOf: url)
            c.openDocumentFromExternalURL(url)
            let document = try XCTUnwrap(c.pdfView.document)
            let page = try XCTUnwrap(document.page(at:0))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(page.thumbnail(of:CGSize(width:240,height:120),for:.mediaBox).tiffRepresentation)))
            let red = try XCTUnwrap(bitmap.colorAt(x:30,y:60)?.usingColorSpace(.sRGB))
            let transparentPaper = try XCTUnwrap(bitmap.colorAt(x:200,y:60)?.usingColorSpace(.sRGB))
            // PDFKit thumbnails apply the display/EDR color transform; assert the
            // red region's channel dominance rather than unmanaged RGB equality.
            XCTAssertGreaterThan(red.redComponent,0.9)
            XCTAssertGreaterThan(red.redComponent - red.greenComponent,0.6)
            XCTAssertGreaterThan(red.redComponent - red.blueComponent,0.6)
            XCTAssertGreaterThan(transparentPaper.redComponent,0.9); XCTAssertGreaterThan(transparentPaper.greenComponent,0.9)
            let session = c.pdfView.rectangleMarkup
            session.canEdit = { true }
            session.undo.beginUndoGrouping()
            let mark = try XCTUnwrap(session.create(on: page, bounds: CGRect(x:10,y:10,width:20,height:20)))
            session.undo.endUndoGrouping()
            XCTAssertTrue(RectangleMarkupRecord.owns(mark))
            let target = dir.appendingPathComponent("saved.pdf")
            var completed: Bool?
            c.saveErrorPresenter = { _ in .alertFirstButtonReturn }
            c.persistDocument(to:target,adoptAsPrimaryDocument:true,busyMessage:"Test",showBusyOverlay:false) { completed = $0 }
            let deadline = Date().addingTimeInterval(15)
            while completed == nil && Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
            XCTAssertEqual(completed,true)
            let reopened = try XCTUnwrap(PDFDocument(url:target))
            XCTAssertEqual(reopened.pageCount,1); XCTAssertEqual(reopened.page(at:0)?.annotations.count,1)
            XCTAssertEqual(reopened.page(at:0)?.bounds(for:.mediaBox).size,CGSize(width:240,height:120))
            XCTAssertEqual(try Data(contentsOf:url),original)
        }
    }
    func testWelcomeFileDropOpensFullResolutionPDFAndReusesTab() throws {
        try fixture { c,w,dir in
            let url = try image(dir); let bytes = try Data(contentsOf: url)
            let root = try XCTUnwrap(c.view as? StartupDropView); let drag = ImageFileDrag(url)
            XCTAssertEqual(root.draggingEntered(drag),.copy)
            guard root.performDragOperation(drag) else { XCTFail("Image file drop must open a PDF-backed document"); return }
            w.layoutIfNeeded()
            let document = try XCTUnwrap(c.pdfView.document)
            let page = try XCTUnwrap(document.page(at: 0))
            XCTAssertEqual(page.bounds(for: .mediaBox).size,CGSize(width:240,height:120))
            XCTAssertEqual(c.openDocumentURL?.pathExtension,"pdf")
            XCTAssertNotEqual(c.openDocumentURL,url)
            XCTAssertTrue(w.title.contains(url.lastPathComponent))
            let tabs = c.sessionDocumentURLs
            XCTAssertTrue(root.performDragOperation(drag))
            XCTAssertTrue(c.pdfView.document === document); XCTAssertEqual(c.sessionDocumentURLs,tabs)
            c.pdfView.autoScales = false; c.pdfView.scaleFactor = 2
            XCTAssertEqual(c.pdfView.scaleFactor,2,accuracy:0.01)
            XCTAssertTrue(c.pdfView.zoom(by: 4))
            w.layoutIfNeeded(); c.pdfView.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(c.pdfView.documentView?.enclosingScrollView)
            let clip = scroll.contentView
            let before = clip.bounds.origin
            clip.scroll(to: CGPoint(x: before.x + 100, y: before.y + 50))
            scroll.reflectScrolledClipView(clip)
            XCTAssertNotEqual(clip.bounds.origin, before, "Imported image remains pannable at high zoom")
            XCTAssertTrue(c.pdfView.document === document)
            XCTAssertEqual(try Data(contentsOf:url),bytes)
        }
    }
    func testCanvasDropReplacesPDFAndCorruptImageLeavesItIntact() throws {
        try fixture { c,w,dir in
            let pdf = PDFDocument(); pdf.insert(PDFPage(),at:0)
            let source = dir.appendingPathComponent("existing.pdf"); XCTAssertTrue(pdf.write(to:source))
            c.openDocument(at:source); let original = c.pdfView.document
            let bad = dir.appendingPathComponent("broken.png"); try Data("broken".utf8).write(to:bad)
            XCTAssertFalse(c.pdfView.performDragOperation(ImageFileDrag(bad)))
            XCTAssertTrue(c.pdfView.document === original)
            let url = try image(dir)
            XCTAssertEqual(c.pdfView.draggingEntered(ImageFileDrag(url)),.copy)
            guard c.pdfView.performDragOperation(ImageFileDrag(url)) else { XCTFail("Canvas must accept images"); return }
            XCTAssertFalse(c.pdfView.document === original)
            XCTAssertEqual(c.pdfView.document?.pageCount,1)
        }
    }
    func testOrientedJPEGAndMultipageTIFFAndAnimatedGIFFirstFrame() throws {
        try fixture { c,w,dir in
            for (type,orientation,frames,count,size) in [(UTType.jpeg,6,1,1,CGSize(width:120,height:240)),(.tiff,1,2,2,CGSize(width:240,height:120)),(.gif,1,2,1,CGSize(width:240,height:120))] {
                let url = try image(dir,type:type,orientation:orientation,frames:frames)
                var opened = false
                let v = StartupDropView(); v.onOpenDroppedPDF = { c.openDocument(at:$0); opened = true }
                guard v.performDragOperation(ImageFileDrag(url)) else { XCTFail("Supported image rejected: \(type)"); continue }
                XCTAssertTrue(opened); XCTAssertEqual(c.pdfView.document?.pageCount,count)
                XCTAssertEqual(c.pdfView.document?.page(at:0)?.bounds(for:.mediaBox).size,size)
            }
        }
    }
}
