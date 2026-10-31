import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class ChromePerformanceTests: XCTestCase {
    private func document(pages: Int = 240, bookmarks: Int = 1000) throws -> PDFDocument {
        let data=NSMutableData();var box=CGRect(x:0,y:0,width:1200,height:1600)
        let ctx=try XCTUnwrap(CGContext(consumer:try XCTUnwrap(CGDataConsumer(data:data)),mediaBox:&box,nil))
        for _ in 0..<pages { ctx.beginPDFPage(nil);ctx.endPDFPage() };ctx.closePDF()
        let doc=try XCTUnwrap(PDFDocument(data:data as Data));let root=PDFOutline()
        for i in 0..<bookmarks { let node=PDFOutline();node.label="A\(i) · Architectural sheet";node.destination=PDFDestination(page:try XCTUnwrap(doc.page(at:i % pages)),at:CGPoint(x:100,y:800));root.insertChild(node,at:i) }
        doc.outlineRoot=root;return doc
    }
    private func fixture(_ body:(MainViewController,NSWindow,PDFDocument)throws->Void)throws {
        _=NSApplication.shared;let c=MainViewController();let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1400,height:900),styleMask:[.titled],backing:.buffered,defer:false)
        w.contentViewController=c;let source=try document()
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("ChromeBench-\(UUID().uuidString).pdf")
        XCTAssertTrue(source.write(to:url));defer { try? FileManager.default.removeItem(at:url) }
        c.openDocument(at:url);let doc=try XCTUnwrap(c.pdfView.document);w.layoutIfNeeded()
        defer { w.makeFirstResponder(nil);w.contentViewController=nil }
        try body(c,w,doc);XCTAssertFalse(w.isVisible)
    }
    func testRepeatedViewportChromeBenchmark() throws {
        try fixture { c,_,doc in
            c.requestChromeRefresh(immediate:true)
            let start=CFAbsoluteTimeGetCurrent()
            for _ in 0..<100 { c.requestChromeRefresh(immediate:true) }
            let elapsed=CFAbsoluteTimeGetCurrent()-start
            print("CHROME_BENCH pages=\(doc.pageCount) bookmarks=1000 refreshes=100 seconds=\(elapsed)")
            XCTAssertEqual(c.pdfView.document?.pageCount,240)
            XCTAssertEqual(doc.outlineRoot?.numberOfChildren,1000)
        }
    }
    func testPrivatePDFChromeBenchmark() throws {
        guard let path=ProcessInfo.processInfo.environment["DRAWBRIDGE_CHROME_BENCHMARK"] else { throw XCTSkip("Optional private PDF chrome benchmark") }
        let url=URL(fileURLWithPath:path);let before=try Data(contentsOf:url)
        let doc=try XCTUnwrap(PDFDocument(url:url));_=NSApplication.shared
        let c=MainViewController();let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1400,height:900),styleMask:[.titled],backing:.buffered,defer:false)
        w.contentViewController=c;c.openDocument(at:url);w.layoutIfNeeded()
        defer { w.makeFirstResponder(nil);w.contentViewController=nil }
        c.requestChromeRefresh(immediate:true)
        let start=CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 { c.requestChromeRefresh(immediate:true) }
        print("PRIVATE_CHROME_BENCH pages=\(doc.pageCount) refreshes=100 seconds=\(CFAbsoluteTimeGetCurrent()-start)")
        XCTAssertEqual(try Data(contentsOf:url),before);XCTAssertFalse(c.hasUnsavedChanges());XCTAssertFalse(w.isVisible)
    }

    func testViewportRefreshDoesNotRebuildSidebarOrRescanRecoveryAndKeepsSelection() throws {
        try fixture { c,_,doc in
            c.requestChromeRefresh(immediate:true)
            let reloads=c.sidebarReloadCount, scans=c.recoveryAvailabilityCache.inspectionCount
            c.pagesTableView.selectRowIndexes(IndexSet(integer:5),byExtendingSelection:false)
            c.bookmarksOutlineView.selectRowIndexes(IndexSet(integer:3),byExtendingSelection:false)
            let selected=c.bookmarksOutlineView.item(atRow:3) as? PDFOutline
            for i in 0..<30 {
                c.pdfView.go(to:try XCTUnwrap(doc.page(at:i)))
                c.pdfView.scaleFactor=1+CGFloat(i)/100
                c.requestChromeRefresh(immediate:true)
            }
            XCTAssertEqual(c.sidebarReloadCount,reloads)
            XCTAssertEqual(c.recoveryAvailabilityCache.inspectionCount,scans)
            XCTAssertEqual(c.pagesTableView.selectedRowIndexes,IndexSet(integer:5))
            XCTAssertTrue(c.bookmarksOutlineView.item(atRow:c.bookmarksOutlineView.selectedRow) as? PDFOutline === selected)
            XCTAssertTrue(c.isSidebarCurrentPage(29))
            let node=PDFOutline();node.label="New sheet bookmark";node.destination=PDFDestination(page:try XCTUnwrap(doc.page(at:2)),at:.zero)
            doc.outlineRoot?.insertChild(node,at:1000)
            c.requestChromeRefresh(immediate:true)
            XCTAssertEqual(c.sidebarReloadCount,reloads+1)
            XCTAssertEqual(c.bookmarksOutlineView.numberOfRows,1001)
            doc.removePage(at:239);c.requestChromeRefresh(immediate:true)
            XCTAssertEqual(c.pagesTableView.numberOfRows,239)
            XCTAssertGreaterThan(c.recoveryAvailabilityCache.inspectionCount,scans)
        }
    }
    func testCurrentPageBadgePreservesThumbnailAndCaption() throws {
        let page=try XCTUnwrap(document(pages:1,bookmarks:0).page(at:0))
        let cell=PageThumbnailCell(frame:NSRect(x:0,y:0,width:200,height:170))
        cell.configure(page:page,number:1,label:"A1.00",current:false)
        let image=NSImage(size:NSSize(width:100,height:100));cell.preview.image=image
        cell.setCurrent(true);XCTAssertEqual(cell.preview.layer?.borderWidth,2)
        cell.setCurrent(false);XCTAssertEqual(cell.preview.layer?.borderWidth,0)
        XCTAssertTrue(cell.preview.image === image);XCTAssertEqual(cell.caption.stringValue,"1 · A1.00")
    }
    private func recoveryDocument(_ recoverable: Bool) throws -> PDFDocument {
        var data=Data("%PDF-1.4\n".utf8);var offsets=[0]
        let objects=["<< /Type /Catalog /Pages 2 0 R \(recoverable ? "/DrawbridgeUnflattenData << /Version 1 >>" : "") >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] >>"]
        for (i,obj) in objects.enumerated() { offsets.append(data.count);data.append(Data("\(i+1) 0 obj\n\(obj)\nendobj\n".utf8)) }
        let xref=data.count;var tail="xref\n0 4\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { tail += String(format:"%010d 00000 n \n",offset) }
        tail += "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n";data.append(Data(tail.utf8))
        return try XCTUnwrap(PDFDocument(data:data))
    }
    func testRecoveryCacheRefreshesAcrossDocumentsReloadsAndNilBacking() throws {
        let cache=PDFRecoveryAvailabilityCache(), plain=try recoveryDocument(false), recovered=try recoveryDocument(true)
        XCTAssertFalse(cache.canUnflatten(plain));let first=cache.inspectionCount
        for _ in 0..<100 { XCTAssertFalse(cache.canUnflatten(plain)) }
        XCTAssertEqual(cache.inspectionCount,first)
        XCTAssertTrue(cache.canUnflatten(recovered));XCTAssertEqual(cache.inspectionCount,first+1)
        XCTAssertFalse(cache.canUnflatten(plain));XCTAssertEqual(cache.inspectionCount,first+2)
        XCTAssertFalse(cache.canUnflatten(nil));XCTAssertTrue(cache.canUnflatten(recovered))
        let fresh=try recoveryDocument(false);XCTAssertFalse(cache.canUnflatten(fresh))
        XCTAssertFalse(cache.canUnflatten(PDFDocument()))
    }

}
