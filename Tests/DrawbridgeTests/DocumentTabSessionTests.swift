import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class DocumentTabSessionTests: XCTestCase {
    private func fixture(pages: Int = 4) throws -> URL {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0.2, alpha: 1))
            context.fill(CGRect(x: 80, y: 100, width: 50, height: 60))
            context.endPDFPage()
        }
        context.closePDF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Tab-\(UUID().uuidString).pdf")
        try (data as Data).write(to: url)
        return url
    }
    private func controller() -> (MainViewController, NSWindow) {
        _ = NSApplication.shared
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.layoutIfNeeded()
        return (controller, window)
    }
    func testCleanTabReusesDocumentAndRestoresPageZoomHistoryAndSearch() throws {
        let a = try fixture(), b = try fixture()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let original = try Data(contentsOf: a)
        let (controller, window) = controller()
        controller.openDocument(at: a)
        let document = try XCTUnwrap(controller.pdfView.document)
        controller.pdfView.navigateToPageFittingWholePageWithHistory(try XCTUnwrap(document.page(at: 2)))
        controller.pdfView.autoScales = false
        controller.pdfView.scaleFactor = 1.4
        controller.toolbarSearchField.stringValue = "floor"
        let state = try XCTUnwrap(controller.pdfView.captureTabViewState())
        controller.openDocument(at: b)
        XCTAssertEqual(controller.documentTabCache.count, 1)
        XCTAssertEqual(controller.toolbarSearchField.stringValue, "")
        controller.openDocument(at: a)
        XCTAssertTrue(controller.pdfView.document === document)
        let restored = try XCTUnwrap(controller.pdfView.captureTabViewState())
        XCTAssertEqual(restored.current.pageIndex, state.current.pageIndex)
        XCTAssertEqual(restored.current.scale, state.current.scale, accuracy: 0.001)
        XCTAssertEqual(restored.back.count, state.back.count)
        XCTAssertEqual(controller.toolbarSearchField.stringValue, "floor")
        XCTAssertEqual(controller.sessionDocumentURLs, [a, b])
        XCTAssertEqual(try Data(contentsOf: a), original)
        XCTAssertFalse(window.isDocumentEdited)
    }
    func testCyclingThreeTabsDoesNotReorderOrSkipTabs() throws {
        let urls = try (0..<3).map { _ in try fixture() }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let (controller, window) = controller()
        for url in urls { controller.openDocument(at: url) }
        for expected in urls {
            controller.commandCycleNextDocument(nil)
            XCTAssertEqual(controller.openDocumentURL, expected)
            XCTAssertEqual(controller.sessionDocumentURLs, urls)
        }
        controller.commandCloseDocument(nil)
        XCTAssertEqual(controller.sessionDocumentURLs, Array(urls.prefix(2)))
        XCTAssertEqual(controller.openDocumentURL, urls[1])
        XCTAssertFalse(window.isDocumentEdited)
    }
    func testExternalReplacementIsReloadedAndDiscardedEditsAreNotCached() throws {
        let a = try fixture(), b = try fixture(), replacement = try fixture(pages: 2)
        defer { [a,b,replacement].forEach { try? FileManager.default.removeItem(at: $0) } }
        let (controller, window) = controller()
        controller.openDocument(at: a)
        let old = try XCTUnwrap(controller.pdfView.document)
        controller.openDocument(at: b)
        try Data(contentsOf: replacement).write(to: a, options: .atomic)
        controller.openDocument(at: a)
        XCTAssertFalse(controller.pdfView.document === old)
        XCTAssertEqual(controller.pdfView.document?.pageCount, 2)
        let unchanged = try Data(contentsOf: a)
        let dirty = try XCTUnwrap(controller.pdfView.document)
        let session = controller.pdfView.rectangleMarkup
        _ = try XCTUnwrap(session.create(on: try XCTUnwrap(dirty.page(at: 0)), bounds: CGRect(x: 50, y: 100, width: 80, height: 60)))
        XCTAssertTrue(window.isDocumentEdited)
        // openDocument is the load operation after the caller approves Discard.
        controller.openDocument(at: b)
        controller.openDocument(at: a)
        XCTAssertFalse(controller.pdfView.document === dirty)
        XCTAssertTrue(RectangleMarkupRecord.capture(try XCTUnwrap(controller.pdfView.document)).isEmpty)
        XCTAssertEqual(try Data(contentsOf: a), unchanged)
    }
    func testCacheEvictsOldestAndRejectsOversizedDocuments() throws {
        let a = try fixture(), b = try fixture()
        defer { [a,b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let cache = DocumentTabCache(maximumBytes: 1_000_000, maximumCount: 1)
        func entry(_ url: URL) throws -> DocumentTabCache.Entry {
            .init(document: try XCTUnwrap(PDFDocument(url: url)), stamp: try XCTUnwrap(PDFMarkupSourceStamp.read(url)), labels: [:], suppressedLabels: [], scaleLocks: [:])
        }
        cache.store(try entry(a), for: a); cache.store(try entry(b), for: b)
        XCTAssertEqual(cache.count, 1)
        XCTAssertNil(cache.take(a)); XCTAssertNotNil(cache.take(b)); XCTAssertEqual(cache.count, 0)
        let small = DocumentTabCache(maximumBytes: 1)
        small.store(try entry(a), for: a)
        XCTAssertEqual(small.count, 0)
    }
    func testSavingAfterCachedTabSwitchUsesCurrentSourceAndPreservesOriginalBytes() async throws {
        let a = try fixture(), b = try fixture()
        defer { [a,b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let original = try Data(contentsOf: a)
        let (controller, window) = controller()
        controller.openDocument(at: a)
        let document = try XCTUnwrap(controller.pdfView.document)
        controller.openDocument(at: b); controller.openDocument(at: a)
        XCTAssertTrue(controller.pdfView.document === document)
        let session = controller.pdfView.rectangleMarkup
        session.fontSize = 19.25
        _ = try XCTUnwrap(session.create(on: try XCTUnwrap(document.page(at: 0)), bounds: CGRect(x: 150,y: 100,width: 200,height: 70), kind: .text, text: "Cached tab save"))
        let expected = RectangleMarkupRecord.capture(document)
        let saved = await withCheckedContinuation { continuation in
            controller.persistDocument(to: a, adoptAsPrimaryDocument: false, busyMessage: "Saving PDF…") { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(saved)
        XCTAssertEqual(try Data(contentsOf: a).prefix(original.count), original)
        XCTAssertEqual(RectangleMarkupRecord.capture(try XCTUnwrap(PDFDocument(url: a))), expected)
        controller.openDocument(at: b); controller.openDocument(at: a)
        XCTAssertTrue(controller.pdfView.document === document)
        XCTAssertEqual(RectangleMarkupRecord.capture(document), expected)
        XCTAssertFalse(window.isDocumentEdited)
    }
    func testLargeDrawingTabReuseLatency() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_TAB_FIXTURE"] else { throw XCTSkip("Set DRAWBRIDGE_TAB_FIXTURE for a representative drawing set") }
        let source = URL(fileURLWithPath: path), other = try fixture()
        defer { try? FileManager.default.removeItem(at: other) }
        let original = try Data(contentsOf: source)
        let (controller, window) = controller()
        var start = Date()
        controller.openDocument(at: source)
        let cold = Date().timeIntervalSince(start)
        let document = try XCTUnwrap(controller.pdfView.document)
        controller.openDocument(at: other)
        start = Date()
        controller.openDocument(at: source)
        let warm = Date().timeIntervalSince(start)
        XCTAssertTrue(controller.pdfView.document === document)
        XCTAssertLessThan(warm, 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(window.isDocumentEdited)
        print("LARGE DRAWING TAB cold=\(cold)s cached=\(warm)s pages=\(document.pageCount)")
    }
}
