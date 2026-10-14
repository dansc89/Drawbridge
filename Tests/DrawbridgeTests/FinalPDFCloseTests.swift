import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class FinalPDFCloseTests: XCTestCase {
    private func fixture() throws -> URL {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        for _ in 0..<3 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FinalClose-\(UUID().uuidString).pdf")
        try (data as Data).write(to: url)
        return url
    }

    private func withController(_ body: (MainViewController, NSWindow) throws -> Void) rethrows {
        _ = NSApplication.shared
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.layoutIfNeeded()
        defer { window.makeFirstResponder(nil); window.contentViewController = nil }
        try body(controller, window)
        XCTAssertFalse(window.isVisible, "Synthetic regressions must never order a window")
    }

    private func assertEmpty(_ c: MainViewController, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(c.pdfView.document, file: file, line: line)
        XCTAssertNil(c.secondaryPDFView, file: file, line: line)
        XCTAssertNil(c.openDocumentURL, file: file, line: line)
        XCTAssertTrue(c.sessionDocumentURLs.isEmpty, file: file, line: line)
        XCTAssertEqual(c.documentTabCache.count, 0, file: file, line: line)
        XCTAssertEqual(c.pdfPaneSplitView.arrangedSubviews.count, 1, file: file, line: line)
        XCTAssertTrue(c.pdfPaneSplitView.isHidden, "No PDF must hide the entire split presentation, not only its active canvas", file: file, line: line)
        XCTAssertTrue(c.pdfView.isHidden, file: file, line: line)
        XCTAssertEqual(c.pdfView.layer?.borderWidth, 0, file: file, line: line)
        XCTAssertTrue((c.pdfPaneSplitView.arrangedSubviews.first as? PDFPaneContainerView)?.header.isHidden == true, file: file, line: line)
    }

    func testClosingFinalSplitPDFRemovesPresentationAndReopensSinglePane() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)
        for activateSecondary in [false, true] {
            try withController { c, w in
                c.openDocument(at: url)
                c.commandToggleSplitView(nil)
                let retired = try XCTUnwrap(activateSecondary ? c.pdfView : c.secondaryPDFView)
                if activateSecondary { c.activatePDFPane(try XCTUnwrap(c.secondaryPDFView)) }
                let survivor = c.pdfView
                XCTAssertEqual(c.pdfPaneSplitView.arrangedSubviews.count, 2)
                c.commandCloseDocument(nil)
                w.layoutIfNeeded()
                assertEmpty(c)
                XCTAssertTrue(c.pdfView === survivor)
                XCTAssertNil(retired.document)
                XCTAssertNil(retired.superview?.superview)
                c.openDocument(at: url)
                w.layoutIfNeeded()
                XCTAssertNotNil(c.pdfView.document)
                XCTAssertFalse(c.pdfView.isHidden)
                XCTAssertFalse(c.pdfPaneSplitView.isHidden)
                XCTAssertNil(c.secondaryPDFView)
                XCTAssertEqual(c.pdfPaneSplitView.arrangedSubviews.count, 1)
                c.commandCloseDocument(nil)
                assertEmpty(c)
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testClosingMultipleTabsThenFinalSecondaryPaneClearsSplitState() throws {
        let a = try fixture(), b = try fixture()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        try withController { c, w in
            c.openDocument(at: a)
            c.openDocument(at: b)
            c.commandToggleSplitView(nil)
            c.activatePDFPane(try XCTUnwrap(c.secondaryPDFView))
            c.commandCloseDocument(nil)
            XCTAssertEqual(c.sessionDocumentURLs, [c.canonicalDocumentURL(a)])
            XCTAssertEqual(c.openDocumentURL, a)
            XCTAssertNotNil(c.pdfView.document)
            XCTAssertNil(c.secondaryPDFView)
            XCTAssertFalse(c.pdfPaneSplitView.isHidden)
            c.commandToggleSplitView(nil)
            c.activatePDFPane(try XCTUnwrap(c.secondaryPDFView))
            c.commandCloseDocument(nil)
            w.layoutIfNeeded()
            assertEmpty(c)
        }
    }

    func testBlockedClosePreservesSplitDocumentAndSession() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        try withController { c, _ in
            c.openDocument(at: url)
            c.commandToggleSplitView(nil)
            c.activatePDFPane(try XCTUnwrap(c.secondaryPDFView))
            let active = c.pdfView, peer = try XCTUnwrap(c.secondaryPDFView)
            let document = active.document, presentation = peer.document
            c.beginBusyIndicator("Close regression")
            defer { c.endBusyIndicator() }
            c.commandCloseDocument(nil)
            XCTAssertTrue(c.pdfView === active)
            XCTAssertTrue(c.secondaryPDFView === peer)
            XCTAssertTrue(active.document === document)
            XCTAssertTrue(peer.document === presentation)
            XCTAssertEqual(c.sessionDocumentURLs, [c.canonicalDocumentURL(url)])
            XCTAssertEqual(c.openDocumentURL, url)
            XCTAssertEqual(c.pdfPaneSplitView.arrangedSubviews.count, 2)
            XCTAssertFalse(c.pdfPaneSplitView.isHidden)
        }
    }
}
