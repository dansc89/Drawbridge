import AppKit
import CoreText
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class PDFCanvasAccessibilityTests: XCTestCase {
    private func document(pages: Int) throws -> PDFDocument {
        let bytes = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let writer = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: bytes)), mediaBox: &media, nil))
        for index in 0..<pages {
            writer.beginPDFPage(nil)
            let text = NSAttributedString(string: "Accessible sheet \(index + 1)", attributes: [.font: NSFont.systemFont(ofSize: 16)])
            writer.textPosition = CGPoint(x: 40, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), writer)
            writer.endPDFPage()
        }
        writer.closePDF()
        return try XCTUnwrap(PDFDocument(data: bytes as Data))
    }

    func testSinglePageTreeIsBoundedAndRetainsPageTextAfterNavigation() async throws {
        _ = NSApplication.shared
        let doc = try document(pages: 259)
        let view = MarkupPDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        view.document = doc; view.go(to: try XCTUnwrap(doc.page(at: 0)))
        window.layoutIfNeeded()
        let first = try XCTUnwrap(view.accessibilityChildren()?.first as? NSAccessibilityElement)
        XCTAssertEqual(view.accessibilityRole(), .scrollArea)
        XCTAssertEqual(first.accessibilityRole(), .staticText)
        XCTAssertEqual(first.accessibilityLabel(), "Page 1 of 259")
        XCTAssertEqual(view.accessibilityChildren()?.count, 1, "Hidden pages must not be traversed by an accessibility client")
        for _ in 0..<100 {
            if (first.accessibilityValue() as? String)?.contains("Accessible sheet 1") == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue((first.accessibilityValue() as? String)?.contains("Accessible sheet 1") == true)
        view.go(to: try XCTUnwrap(doc.page(at: 258)))
        let last = try XCTUnwrap(view.accessibilityChildren()?.first as? NSAccessibilityElement)
        XCTAssertEqual(last.accessibilityLabel(), "Page 259 of 259")
        for _ in 0..<100 {
            if (last.accessibilityValue() as? String)?.contains("Accessible sheet 259") == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue((last.accessibilityValue() as? String)?.contains("Accessible sheet 259") == true)
        XCTAssertEqual(view.accessibilityChildren()?.count, 1)
    }

    func testAccessibleMarkupPressResolvesToCanonicalAnnotationInInactivePane() async throws {
        _ = NSApplication.shared
        let doc = try document(pages: 3)
        let controller = MainViewController()
        let window = NSWindow(contentRect: CGRect(x:0,y:0,width:1500,height:900), styleMask:[.titled],backing:.buffered,defer:false)
        window.contentViewController = controller
        defer { window.contentViewController = nil }
        controller.pdfView.setMarkupDocument(doc)
        controller.pdfView.go(to: try XCTUnwrap(doc.page(at:0)))
        controller.pdfView.rectangleMarkup.canEdit = { true }
        let original = try XCTUnwrap(controller.pdfView.rectangleMarkup.create(on: XCTUnwrap(doc.page(at:0)),bounds:CGRect(x:200,y:300,width:100,height:100),kind:.rectangle))
        controller.commandToggleSplitView(nil); window.layoutIfNeeded()
        let peer = try XCTUnwrap(controller.secondaryPDFView)
        let item = try XCTUnwrap(peer.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.first { $0.accessibilityRole() == .layoutItem })
        XCTAssertTrue(item.accessibilityPerformPress())
        for _ in 0..<100 {
            if controller.pdfView === peer { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(controller.pdfView === peer)
        XCTAssertTrue(peer.document === doc)
        XCTAssertTrue(peer.rectangleMarkup.selected === original, "Accessibility must select the editing object, not its inactive display copy")
    }

    func testAccessibleImportedOverlapRetainsTheChosenAnnotation() throws {
        _ = NSApplication.shared
        let doc = try document(pages: 3)
        let page = try XCTUnwrap(doc.page(at: 0))
        let first = PDFAnnotation(bounds: CGRect(x: 200, y: 300, width: 100, height: 100), forType: .square, withProperties: nil)
        let second = PDFAnnotation(bounds: first.bounds, forType: .square, withProperties: nil)
        first.color = .red; second.color = .blue
        page.addAnnotation(first); page.addAnnotation(second)
        let controller = MainViewController()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1500, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { window.contentViewController = nil }
        controller.pdfView.setMarkupDocument(doc)
        controller.pdfView.rectangleMarkup.canEdit = { true }
        controller.commandToggleSplitView(nil); window.layoutIfNeeded()
        let peer = try XCTUnwrap(controller.secondaryPDFView)
        let displayed = try XCTUnwrap(peer.currentPage?.annotations.last)
        XCTAssertNil(RectangleMarkupRecord.identity(displayed))
        XCTAssertTrue(peer.activateAccessibleAnnotation(displayed))
        XCTAssertTrue(peer.rectangleMarkup.selected === second, "Identical bounds and text must not select a different imported annotation")
    }
}
