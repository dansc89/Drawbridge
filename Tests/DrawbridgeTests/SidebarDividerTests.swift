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
    func testNavigationLabelsRestoreImmediatelyWithoutFocusTransition() throws {
        try fixture { c,w,left,_,url in
            let control = try XCTUnwrap(descendants(c.view).compactMap { $0 as? NSSegmentedControl }
                .first { $0.segmentCount == 2 && $0.label(forSegment: 0) == "Pages" })
            let document = try XCTUnwrap(c.pdfView.document)
            let original = try Data(contentsOf: url)
            c.bookmarksOutlineView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            c.pagesTableView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
            w.makeFirstResponder(c.pdfView)
            let responder = w.firstResponder
            let page = c.pdfView.currentPage
            @MainActor func raster() throws -> Data {
                let rep = try XCTUnwrap(control.bitmapImageRepForCachingDisplay(in: control.bounds))
                control.cacheDisplay(in: control.bounds, to: rep)
                return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            }
            for (cycle, mode) in [1,0,1,0].enumerated() {
                control.selectedSegment = mode
                XCTAssertTrue(control.sendAction(try XCTUnwrap(control.action), to: control.target))
                w.layoutIfNeeded()
                try drag(left, delta: mode == 0 ? 20 : -10, window: w)
                let width = left.frame.midX
                let frame = control.convert(control.bounds, to: c.view)
                let before = try raster()
                try click(left, window: w)
                // Exercise mode changes while hidden too, without changing the final selection.
                control.selectedSegment = 1 - mode
                XCTAssertTrue(control.sendAction(try XCTUnwrap(control.action), to: control.target))
                control.selectedSegment = mode
                XCTAssertTrue(control.sendAction(try XCTUnwrap(control.action), to: control.target))
                w.setContentSize(NSSize(width: mode == 0 ? 1300 : 1600, height: 900))
                w.layoutIfNeeded()
                try click(left, window: w)

                XCTAssertEqual(control.convert(control.bounds, to: c.view).minX, frame.minX, accuracy: 0.5)
                XCTAssertEqual(control.bounds.width, frame.width, accuracy: 0.5)
                // Native bezels may overhang the layout row (for example, by 2 pt on macOS 15).
                XCTAssertGreaterThanOrEqual(control.alignmentRect(forFrame: control.frame).minX, 0, "Labels must remain inside their row's alignment rect")
                let reopened = try raster()
                if let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_SIDEBAR_EVIDENCE_DIR"] {
                    let directory = URL(fileURLWithPath: path, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try before.write(to: directory.appendingPathComponent("cycle-\(cycle)-before.png"))
                    try reopened.write(to: directory.appendingPathComponent("cycle-\(cycle)-reopened.png"))
                }
                XCTAssertEqual(reopened, before, "Native segmented labels must render identically immediately after reopening, without a focus transition")
                XCTAssertEqual(left.frame.midX, width, accuracy: 0.5)
                XCTAssertEqual(control.selectedSegment, mode)
                XCTAssertTrue(w.firstResponder === responder)
                XCTAssertTrue(c.pdfView.document === document)
                XCTAssertTrue(c.pdfView.currentPage === page)
                XCTAssertEqual(c.bookmarksOutlineView.selectedRowIndexes, IndexSet(integer: 1))
                XCTAssertEqual(c.pagesTableView.selectedRowIndexes, IndexSet(integer: 2))
                XCTAssertFalse(c.hasUnsavedChanges())
            }
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
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
    func testBottomDividerTogglePreservesListStateAndPDF() throws {
        try fixture { c,w,_,_,url in
            let bytes=try Data(contentsOf:url), divider=c.markupsDivider
            XCTAssertTrue(divider.horizontal);XCTAssertTrue(divider.collapsed)
            XCTAssertFalse(divider.isHidden);XCTAssertEqual(divider.frame.height,12,accuracy:0.5)
            let canvasHeight=c.pdfView.bounds.height
            try click(divider,window:w)
            XCTAssertTrue(c.isMarkupsPanelVisible);XCTAssertFalse(c.markupsPanel.isHidden)
            XCTAssertLessThan(c.pdfView.bounds.height,canvasHeight-150)
            c.markupsSearchField.stringValue="Keep filter"
            c.markupFilterText="keep filter"
            c.markupItems=[MarkupItem(pageIndex:0,annotation:PDFAnnotation(bounds:.zero,forType:.square,withProperties:nil)),MarkupItem(pageIndex:1,annotation:PDFAnnotation(bounds:.zero,forType:.circle,withProperties:nil))]
            c.markupsTable.reloadData()
            c.isRestoringMarkupSelection=true
            c.markupsTable.selectRowIndexes(IndexSet(integersIn:0..<2),byExtendingSelection:false)
            c.isRestoringMarkupSelection=false
            c.pendingMarkupsRefreshWorkItem?.cancel();c.pendingMarkupsRefreshWorkItem=nil
            try click(divider,window:w)
            XCTAssertTrue(c.markupsPanel.isHidden);XCTAssertTrue(divider.collapsed)
            XCTAssertEqual(c.pdfView.bounds.height,canvasHeight,accuracy:2)
            try click(divider,window:w)
            XCTAssertEqual(c.markupsTable.selectedRowIndexes,IndexSet(integersIn:0..<2))
            XCTAssertEqual(c.markupsSearchField.stringValue,"Keep filter")
            XCTAssertNil(c.pendingMarkupsRefreshWorkItem,"Toggling must not enqueue a selection-resetting rebuild")
            XCTAssertFalse(descendants(c.markupsPanel).contains{($0 as? NSButton)?.title=="Hide"})
            XCTAssertFalse(descendants(c.view).contains{$0.identifier?.rawValue=="drawbridgeMarkupsList"})
            XCTAssertFalse(c.hasUnsavedChanges());XCTAssertEqual(try Data(contentsOf:url),bytes)
        }
    }
    func testBottomDividerVerticalResizeReopenAndSplitLayout() throws {
        try fixture { c,w,left,right,_ in
            let divider=c.markupsDivider
            try click(divider,window:w)
            let original=c.markupsPanel.frame.height
            let start=divider.convert(NSPoint(x:divider.bounds.midX,y:divider.bounds.midY),to:nil)
            let end=NSPoint(x:start.x,y:start.y+70)
            divider.mouseDown(with:try event(.leftMouseDown,start,window:w))
            divider.mouseDragged(with:try event(.leftMouseDragged,end,window:w))
            divider.mouseUp(with:try event(.leftMouseUp,end,window:w));w.layoutIfNeeded()
            XCTAssertTrue(c.isMarkupsPanelVisible)
            XCTAssertEqual(c.markupsPanel.frame.height,original+70,accuracy:2)
            try click(divider,window:w);try click(divider,window:w)
            XCTAssertEqual(c.markupsPanel.frame.height,original+70,accuracy:2)
            c.commandToggleSplitView(nil);w.layoutIfNeeded()
            try click(left,window:w);try click(right,window:w)
            try click(divider,window:w);try click(divider,window:w)
            XCTAssertNotNil(c.secondaryPDFView);XCTAssertTrue(c.isMarkupsPanelVisible)
            w.setContentSize(NSSize(width:1300,height:700));w.layoutIfNeeded()
            try click(divider,window:w);try click(divider,window:w)
            XCTAssertGreaterThan(c.pdfView.bounds.height,100)
        }
    }
    func testBottomDividerAccessibilityMenuAndHiddenFocus() throws {
        try fixture { c,w,_,_,_ in
            let divider=c.markupsDivider
            XCTAssertEqual(divider.accessibilityLabel(),"Show Markups List")
            XCTAssertTrue(divider.accessibilityPerformPress());w.layoutIfNeeded()
            XCTAssertEqual(divider.accessibilityLabel(),"Collapse Markups List")
            XCTAssertTrue(w.makeFirstResponder(c.markupsSearchField))
            c.commandToggleMarkupsList(nil);w.layoutIfNeeded()
            XCTAssertTrue(divider.collapsed);XCTAssertTrue(w.firstResponder === c.pdfView)
            XCTAssertTrue(divider.accessibilityPerformPress());w.layoutIfNeeded()
            XCTAssertFalse(divider.collapsed)
        }
    }
}
