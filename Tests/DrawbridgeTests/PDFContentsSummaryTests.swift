import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

private final class SummaryCountingPage: PDFPage {
    var annotationReads = 0
    override var annotations: [PDFAnnotation] {
        annotationReads += 1
        return super.annotations
    }
}

@MainActor
final class PDFContentsSummaryTests: XCTestCase {
    private func summary(in view: NSView) -> String? {
        if let text = view as? NSTextField, text.stringValue.hasPrefix("Pages:") { return text.stringValue }
        return view.subviews.lazy.compactMap { self.summary(in: $0) }.first
    }

    func testEditingOnePageDoesNotRescanOtherConsultantAnnotations() throws {
        _ = NSApplication.shared
        let controller = MainViewController(); _ = controller.view
        let document = PDFDocument()
        var pages: [SummaryCountingPage] = []
        for index in 0..<80 {
            let page = SummaryCountingPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
            for _ in 0..<100 {
                page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .square, withProperties: nil))
            }
            document.insert(page, at: index); pages.append(page)
        }
        controller.pdfView.setMarkupDocument(document)
        controller.markPageMarkupCacheDirty(nil)
        pages.forEach { $0.annotationReads = 0 }
        let coldStart = Date()
        controller.updatePDFContentsSummary()
        let coldSeconds = Date().timeIntervalSince(coldStart)
        XCTAssertTrue(pages.allSatisfy { $0.annotationReads == 1 })
        XCTAssertTrue(try XCTUnwrap(summary(in: controller.view)).contains("Annotations: 8000\n"))
        pages.forEach { $0.annotationReads = 0 }
        controller.updatePDFContentsSummary()
        XCTAssertTrue(pages.allSatisfy { $0.annotationReads == 0 })
        let edited = pages[25]
        edited.addAnnotation(PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 40, height: 40), forType: .circle, withProperties: nil))
        controller.markPageMarkupCacheDirty(edited)
        let editStart = Date()
        controller.updatePDFContentsSummary()
        let editSeconds = Date().timeIntervalSince(editStart)
        XCTAssertEqual(pages.filter { $0 !== edited }.reduce(0) { $0 + $1.annotationReads }, 0)
        XCTAssertEqual(edited.annotationReads, 1)
        XCTAssertTrue(try XCTUnwrap(summary(in: controller.view)).contains("Annotations: 8001\n"))
        print("CONTENTS SUMMARY: 8000 annotations cold=\(coldSeconds)s; one-page edit=\(editSeconds)s")
        controller.markPageMarkupCacheDirty(nil)
        pages.forEach { $0.annotationReads = 0 }
        controller.updatePDFContentsSummary()
        XCTAssertTrue(pages.allSatisfy { $0.annotationReads == 1 })
    }

    func testSummaryUpdatesFlagsDeletionPageCountAndDocumentSwitching() throws {
        _ = NSApplication.shared
        let controller = MainViewController(); _ = controller.view
        let document = PDFDocument(), page = SummaryCountingPage()
        let link = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .link, withProperties: nil)
        link.shouldPrint = false; link.shouldDisplay = false
        page.addAnnotation(link); document.insert(page, at: 0)
        controller.pdfView.setMarkupDocument(document)
        controller.updatePDFContentsSummary()
        var text = try XCTUnwrap(summary(in: controller.view))
        XCTAssertTrue(text.contains("Non-print items: 1\n")); XCTAssertTrue(text.contains("Hidden items: 1\n")); XCTAssertTrue(text.contains("Links: 1\n"))
        link.shouldPrint = true; link.shouldDisplay = true
        controller.markPageMarkupCacheDirty(page); controller.updatePDFContentsSummary()
        text = try XCTUnwrap(summary(in: controller.view))
        XCTAssertTrue(text.contains("Non-print items: 0\n")); XCTAssertTrue(text.contains("Hidden items: 0\n"))
        page.removeAnnotation(link)
        controller.markPageMarkupCacheDirty(page); controller.updatePDFContentsSummary()
        XCTAssertTrue(try XCTUnwrap(summary(in: controller.view)).contains("Annotations: 0\n"))
        let second = SummaryCountingPage()
        second.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .circle, withProperties: nil))
        document.insert(second, at: 0); controller.updatePDFContentsSummary()
        text = try XCTUnwrap(summary(in: controller.view))
        XCTAssertTrue(text.contains("Pages: 2\n")); XCTAssertTrue(text.contains("Annotations: 1\n")); XCTAssertTrue(text.contains("Circle: 1"))
        let replacement = PDFDocument(); replacement.insert(PDFPage(), at: 0)
        controller.pdfView.setMarkupDocument(replacement); controller.updatePDFContentsSummary()
        XCTAssertTrue(try XCTUnwrap(summary(in: controller.view)).contains("Annotations: 0\n"))
    }
}
