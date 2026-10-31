import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class SidebarDividerTests: XCTestCase {
    private func event(_ type: NSEvent.EventType, _ point: NSPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
    }
    private func click(_ divider: SidebarDividerView, window: NSWindow) throws {
        let point=divider.convert(NSPoint(x:divider.bounds.midX,y:divider.bounds.midY),to:nil)
        let root=try XCTUnwrap(window.contentView)
        XCTAssertTrue(root.hitTest(root.convert(point,from:nil)) === divider,"Divider must receive input at its visible center")
        divider.mouseDown(with:try event(.leftMouseDown,point,window:window))
        divider.mouseUp(with:try event(.leftMouseUp,point,window:window))
        window.layoutIfNeeded()
    }
    private func drag(_ divider: SidebarDividerView, delta: CGFloat, window: NSWindow) throws {
        let start=divider.convert(NSPoint(x:divider.bounds.midX,y:divider.bounds.midY),to:nil)
        let end=NSPoint(x:start.x+delta,y:start.y)
        divider.mouseDown(with:try event(.leftMouseDown,start,window:window))
        divider.mouseDragged(with:try event(.leftMouseDragged,end,window:window))
        divider.mouseUp(with:try event(.leftMouseUp,end,window:window));window.layoutIfNeeded()
    }
    private func descendants(_ v:NSView)->[NSView] { [v]+v.subviews.flatMap(descendants) }
    private func fixture(_ body:(MainViewController,NSWindow,SidebarDividerView,SidebarDividerView,URL)throws->Void)throws {
        _=NSApplication.shared
        let defaults=UserDefaults.standard, oldCollapsed=defaults.object(forKey:"DrawbridgeSidebarCollapsed"), oldWidth=defaults.object(forKey:"DrawbridgeSidebarWidth")
        defer { defaults.set(oldCollapsed,forKey:"DrawbridgeSidebarCollapsed");defaults.set(oldWidth,forKey:"DrawbridgeSidebarWidth") }
        let data=NSMutableData();var box=CGRect(x:0,y:0,width:1200,height:1600)
        let ctx=try XCTUnwrap(CGContext(consumer:try XCTUnwrap(CGDataConsumer(data:data)),mediaBox:&box,nil))
        for _ in 0..<3 {ctx.beginPDFPage(nil);ctx.endPDFPage()};ctx.closePDF()
        let doc=try XCTUnwrap(PDFDocument(data:data as Data));let root=PDFOutline()
        for i in 0..<3 {let node=PDFOutline();node.label="Sheet \(i)";node.destination=PDFDestination(page:doc.page(at:i)!,at:.zero);root.insertChild(node,at:i)};doc.outlineRoot=root
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("Divider-\(UUID().uuidString).pdf");XCTAssertTrue(doc.write(to:url));defer{try? FileManager.default.removeItem(at:url)}
        let c=MainViewController();let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1600,height:1000),styleMask:[.titled],backing:.buffered,defer:false)
        w.contentViewController=c;c.openDocument(at:url);w.layoutIfNeeded()
        if c.rectangleToolbar.propertiesController.view.isHidden {c.toggleSidebar()};w.layoutIfNeeded()
        defer{w.makeFirstResponder(nil);w.contentViewController=nil}
        let controls=descendants(c.view).compactMap{$0 as? SidebarDividerView}
        let left=try XCTUnwrap(controls.first{$0.identifier?.rawValue=="navigationSidebarDivider"}), right=try XCTUnwrap(controls.first{$0.identifier?.rawValue=="propertiesSidebarDivider"})
        try body(c,w,left,right,url);XCTAssertFalse(w.isVisible)
    }
    func testBothDividersClickCollapseAndReopenWithMoreCanvasAndSelectionIntact() throws {
        try fixture {c,w,left,right,url in
            let original=try Data(contentsOf:url)
            c.bookmarksOutlineView.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
            c.pagesTableView.selectRowIndexes(IndexSet(integer:2),byExtendingSelection:false)
            let before=c.pdfView.bounds.width
            try click(left,window:w);XCTAssertTrue(left.collapsed);XCTAssertFalse(left.isHidden)
            XCTAssertGreaterThan(c.pdfView.bounds.width,before+150)
            try click(right,window:w);XCTAssertTrue(right.collapsed);XCTAssertFalse(right.isHidden)
            XCTAssertTrue(c.rectangleToolbar.propertiesController.view.isHidden)
            XCTAssertGreaterThan(c.pdfView.bounds.width,before+400)
            try click(left,window:w);try click(right,window:w)
            XCTAssertFalse(left.collapsed);XCTAssertFalse(right.collapsed)
            XCTAssertEqual(c.pdfView.bounds.width,before,accuracy:3)
            XCTAssertEqual(c.bookmarksOutlineView.selectedRowIndexes,IndexSet(integer:1))
            XCTAssertEqual(c.pagesTableView.selectedRowIndexes,IndexSet(integer:2))
            XCTAssertFalse(descendants(c.rectangleToolbar.propertiesController.view).contains{($0 as? NSButton)?.title=="Hide"})
            XCTAssertFalse(c.hasUnsavedChanges());XCTAssertEqual(try Data(contentsOf:url),original)
        }
    }
    func testDraggingResizesWithoutCollapsingAndRestoresEachWidth() throws {
        try fixture {c,w,left,right,_ in
            let initial=left.frame.midX
            try drag(left,delta:60,window:w)
            XCTAssertFalse(left.collapsed);XCTAssertEqual(left.frame.midX,initial+60,accuracy:2)
            let width=left.frame.midX
            try click(left,window:w);try click(left,window:w);XCTAssertEqual(left.frame.midX,width,accuracy:2)
            let inspector=c.rectangleToolbar.propertiesController.view
            let old=inspector.frame.width
            try drag(right,delta:-35,window:w)
            XCTAssertFalse(right.collapsed);XCTAssertFalse(inspector.isHidden)
            XCTAssertEqual(inspector.frame.width,min(420,old+35),accuracy:2)
            let saved=inspector.frame.width
            try click(right,window:w);try click(right,window:w);XCTAssertEqual(inspector.frame.width,saved,accuracy:2)
        }
    }
    func testCollapsedEdgesSurviveDocumentReloadResizeAndAccessibilityPress() throws {
        try fixture {c,w,left,right,url in
            try click(left,window:w);try click(right,window:w)
            c.openDocument(at:url);w.setContentSize(NSSize(width:1500,height:900));w.layoutIfNeeded()
            XCTAssertTrue(left.collapsed);XCTAssertTrue(right.collapsed)
            XCTAssertTrue(left.accessibilityLabel()?.hasPrefix("Show") == true)
            XCTAssertTrue(right.accessibilityLabel()?.hasPrefix("Show") == true)
            XCTAssertTrue(left.accessibilityPerformPress());XCTAssertTrue(right.accessibilityPerformPress());w.layoutIfNeeded()
            XCTAssertFalse(left.collapsed);XCTAssertFalse(right.collapsed)
            try click(left,window:w);try click(right,window:w)
            // Split layout must not remove the collapsed reopen controls.
            c.commandToggleSplitView(nil);w.layoutIfNeeded()
            try click(left,window:w);try click(right,window:w)
            XCTAssertNotNil(c.secondaryPDFView)
        }
    }
    func testDragBackToOriginNeverTogglesAndSmallClickJitterDoes() throws {
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:100,height:300),styleMask:[.titled],backing:.buffered,defer:false)
        let divider=SidebarDividerView(frame:NSRect(x:0,y:0,width:12,height:300));w.contentView=divider
        var clicks=0,starts=0;var deltas:[CGFloat]=[]
        divider.onToggle={clicks+=1};divider.onResizeStart={starts+=1};divider.onResize={deltas.append($0)}
        let start=NSPoint(x:6,y:100), moved=NSPoint(x:26,y:100)
        divider.mouseDown(with:try event(.leftMouseDown,start,window:w))
        divider.mouseDragged(with:try event(.leftMouseDragged,moved,window:w))
        divider.mouseDragged(with:try event(.leftMouseDragged,start,window:w))
        divider.mouseUp(with:try event(.leftMouseUp,start,window:w))
        XCTAssertEqual(clicks,0);XCTAssertEqual(starts,1);XCTAssertEqual(deltas,[20,0])
        divider.mouseDown(with:try event(.leftMouseDown,start,window:w))
        divider.mouseUp(with:try event(.leftMouseUp,NSPoint(x:7,y:100),window:w));XCTAssertEqual(clicks,1)
        divider.mouseUp(with:try event(.leftMouseUp,start,window:w));XCTAssertEqual(clicks,1)
    }
}
