import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class ReadingPositionTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "ReadingPositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func fixture(rotation: Int = 0) throws -> URL {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 1200, height: 1600)
        let ctx = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        for _ in 0..<4 { ctx.beginPDFPage(nil); ctx.closePath(); ctx.endPDFPage() }
        ctx.closePDF()
        let doc = try XCTUnwrap(PDFDocument(data: data as Data))
        for i in 0..<doc.pageCount { doc.page(at: i)?.rotation = rotation }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Reading-\(UUID().uuidString).pdf")
        XCTAssertTrue(doc.write(to: url))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func controller(_ store: SavedReadingPositionStore, _ body: (MainViewController, NSWindow) throws -> Void) rethrows {
        _ = NSApplication.shared
        let c = MainViewController(); c.readingPositionStore = store
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentViewController = c; w.layoutIfNeeded()
        defer { w.makeFirstResponder(nil); w.contentViewController = nil }
        try body(c,w)
        XCTAssertFalse(w.isVisible)
    }
    private func move(_ c: MainViewController, page: Int, zoom: CGFloat, point: NSPoint) throws -> MarkupPDFView.TabViewState {
        let p = try XCTUnwrap(c.pdfView.document?.page(at: page))
        c.pdfView.autoScales = false; c.pdfView.scaleFactor = zoom
        c.pdfView.go(to: p); c.pdfView.centerViewport(on: point)
        return try XCTUnwrap(c.pdfView.captureTabViewState())
    }
    private func assertPosition(_ c: MainViewController, _ expected: MarkupPDFView.TabViewState, file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try XCTUnwrap(c.pdfView.captureTabViewState())
        XCTAssertEqual(actual.current.pageIndex, expected.current.pageIndex, file: file, line: line)
        XCTAssertEqual(actual.current.scale, expected.current.scale, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.viewportCenter.x, expected.viewportCenter.x, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.viewportCenter.y, expected.viewportCenter.y, accuracy: 1, file: file, line: line)
    }
    func testCloseReopenAndNewControllerRestoreRotatedPDFWithoutWritingIt() throws {
        let d = defaults()
        for rotation in [0,90,180,270] {
            let url = try fixture(rotation: rotation), bytes = try Data(contentsOf: url)
            var expected: MarkupPDFView.TabViewState!
            try controller(SavedReadingPositionStore(defaults:d)) { c,w in
                c.openDocument(at:url); w.layoutIfNeeded()
                expected = try move(c,page:2,zoom:2,point:NSPoint(x:650,y:900))
                c.commandCloseDocument(nil); XCTAssertNil(c.pdfView.document)
                c.openDocument(at:url); w.layoutIfNeeded(); try assertPosition(c,expected)
            }
            try controller(SavedReadingPositionStore(defaults:d)) { c,w in
                c.openDocument(at:url); w.layoutIfNeeded(); try assertPosition(c,expected)
                XCTAssertFalse(c.hasUnsavedChanges())
            }
            XCTAssertEqual(try Data(contentsOf:url),bytes)
        }
    }
    func testSwitchTabsAndQuitCaptureEachDocumentIndependently() throws {
        let d=defaults(), a=try fixture(), b=try fixture()
        var first:MarkupPDFView.TabViewState!, second:MarkupPDFView.TabViewState!
        try controller(SavedReadingPositionStore(defaults:d)) { c,_ in
            c.openDocument(at:a); first=try move(c,page:1,zoom:2,point:NSPoint(x:500,y:700))
            c.openDocument(at:b); second=try move(c,page:3,zoom:3,point:NSPoint(x:750,y:1100))
            XCTAssertTrue(c.confirmAllDocumentsForClose())
        }
        try controller(SavedReadingPositionStore(defaults:d)) { c,_ in
            c.openDocument(at:a); try assertPosition(c,first)
            c.openDocument(at:b); try assertPosition(c,second)
        }
    }
    func testInvalidChangedDocumentAndCorruptPreferencesFallBackSafely() throws {
        let d=defaults(), store=SavedReadingPositionStore(defaults:d), url=try fixture()
        let doc=try XCTUnwrap(PDFDocument(url:url))
        let state=MarkupPDFView.TabViewState(current:.init(pageIndex:2,point:.zero,scale:2),back:[],forward:[],autoScales:false,viewportCenter:NSPoint(x:500,y:700))
        XCTAssertNil(store.load(for:url,document:doc))
        store.save(state,for:url,document:doc); XCTAssertNotNil(store.load(for:url,document:doc))
        doc.page(at:2)?.rotation=90; XCTAssertNil(store.load(for:url,document:doc))
        doc.page(at:2)?.rotation=0; doc.removePage(at:3); XCTAssertNil(store.load(for:url,document:doc))
        d.set(Data("invalid".utf8),forKey:"Drawbridge.savedReadingPositions.v1")
        XCTAssertNil(store.load(for:url,document:doc))
        let invalid=MarkupPDFView.TabViewState(current:.init(pageIndex:0,point:.zero,scale:.nan),back:[],forward:[],autoScales:false,viewportCenter:.zero)
        store.save(invalid,for:url,document:doc); XCTAssertNil(store.load(for:url,document:doc))
    }
    func testSplitQuitKeepsFocusedPositionAndOtherPDFPosition() throws {
        let d=defaults(), a=try fixture(), b=try fixture()
        var first:MarkupPDFView.TabViewState!, second:MarkupPDFView.TabViewState!
        try controller(SavedReadingPositionStore(defaults:d)) { c,w in
            c.openDocument(at:a); c.commandToggleSplitView(nil); w.layoutIfNeeded()
            first=try move(c,page:2,zoom:2,point:NSPoint(x:600,y:900))
            // Same-PDF peer has a different position; it must not win on quit.
            let peer=try XCTUnwrap(c.secondaryPDFView)
            peer.go(to:try XCTUnwrap(peer.document?.page(at:0)))
            XCTAssertTrue(c.confirmAllDocumentsForClose())
        }
        try controller(SavedReadingPositionStore(defaults:d)) { c,w in
            c.openDocument(at:a); try assertPosition(c,first)
            c.commandToggleSplitView(nil); w.layoutIfNeeded()
            c.activatePDFPane(try XCTUnwrap(c.secondaryPDFView))
            c.openDocument(at:b)
            second=try move(c,page:3,zoom:2.5,point:NSPoint(x:650,y:1000))
            XCTAssertTrue(c.confirmAllDocumentsForClose())
        }
        try controller(SavedReadingPositionStore(defaults:d)) { c,_ in
            c.openDocument(at:a); try assertPosition(c,first)
            c.openDocument(at:b); try assertPosition(c,second)
        }
    }
    func testCanonicalAliasesAndBoundedLocalHistory() throws {
        let d=defaults(), store=SavedReadingPositionStore(defaults:d), url=try fixture()
        let doc=try XCTUnwrap(PDFDocument(url:url))
        let state=MarkupPDFView.TabViewState(current:.init(pageIndex:1,point:.zero,scale:2),back:[],forward:[],autoScales:true,viewportCenter:NSPoint(x:400,y:800))
        let alias=url.deletingLastPathComponent().appendingPathComponent("alias-\(UUID().uuidString).pdf")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:url)
        defer { try? FileManager.default.removeItem(at:alias) }
        store.save(state,for:alias,document:doc)
        XCTAssertTrue(try XCTUnwrap(store.load(for:url,document:doc)).autoScales)
        for i in 0..<205 { store.save(state,for:url.deletingLastPathComponent().appendingPathComponent("limit-\(i).pdf"),document:doc) }
        let data=try XCTUnwrap(d.data(forKey:"Drawbridge.savedReadingPositions.v1"))
        let records=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(records.count,200)
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains(url.path))
    }

}
