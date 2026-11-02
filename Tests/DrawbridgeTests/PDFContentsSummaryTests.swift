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
    func testSaveCaptureReadsEachPageOnceAndRepairsDuplicateMarkupIdentities() throws {
        let document = PDFDocument()
        var pages: [SummaryCountingPage] = []
        for index in 0..<80 {
            let page = SummaryCountingPage()
            for _ in 0..<100 {
                page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .square, withProperties: nil))
            }
            let owned = PDFAnnotation(bounds: CGRect(x: 30, y: 30, width: 20, height: 20), forType: .square, withProperties: nil)
            owned.userName = RectangleMarkupRecord.prefix + "duplicate"
            page.addAnnotation(owned)
            document.insert(page, at: index)
            page.annotationReads = 0
            pages.append(page)
        }
        let records = RectangleMarkupRecord.capture(document)
        XCTAssertEqual(records.count, 80)
        XCTAssertEqual(Set(records.map(\.id)).count, 80)
        XCTAssertEqual(records.map(\.pageIndex), Array(0..<80))
        XCTAssertTrue(pages.allSatisfy { $0.annotationReads == 1 })
        XCTAssertEqual(RectangleMarkupRecord.capture(document), records)
        XCTAssertTrue(pages.allSatisfy { $0.annotations.count == 101 })
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    func testNavigationHasNoContentsSectionAndBothModesRemainUsable() throws {
        _ = NSApplication.shared
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        let controls = descendants(of: controller.view)
        let mode = try XCTUnwrap(controls.compactMap { $0 as? NSSegmentedControl }.first {
            $0.segmentCount == 2 && $0.label(forSegment: 0) == "Pages" && $0.label(forSegment: 1) == "Bookmarks"
        })
        let stack = try XCTUnwrap(mode.superview?.superview as? NSStackView)

        func assertNoContentsSection(file: StaticString = #filePath, line: UInt = #line) {
            let views = descendants(of: stack)
            let labels = views.compactMap { ($0 as? NSTextField)?.stringValue }
            XCTAssertFalse(labels.contains("PDF Contents"), file: file, line: line)
            XCTAssertFalse(labels.contains { $0.hasPrefix("Pages:") || $0.contains("Top types:") || $0 == "No PDF loaded" }, file: file, line: line)
            XCTAssertFalse(views.compactMap { $0 as? NSButton }.contains {
                $0.toolTip == "Show or hide PDF contents details"
            }, file: file, line: line)
            XCTAssertFalse(stack.arrangedSubviews.contains { $0 is NSStackView && $0 !== mode.superview },
                           "No trailing summary stack/separator may reserve navigation space", file: file, line: line)
        }
        assertNoContentsSection()

        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        for _ in 0..<3 {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 20, y: 30, width: 200, height: 100))
            context.endPDFPage()
        }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        let page = try XCTUnwrap(document.page(at: 1))
        let annotation = PDFAnnotation(bounds: CGRect(x: 40, y: 50, width: 60, height: 70), forType: .square, withProperties: nil)
        annotation.contents = "Consultant annotation"
        page.addAnnotation(annotation)
        let before = (0..<3).map { document.page(at: $0)?.thumbnail(of: NSSize(width: 180, height: 240), for: .mediaBox).tiffRepresentation }
        let root = PDFOutline(), bookmark = PDFOutline()
        bookmark.label = "Third sheet"
        bookmark.destination = PDFDestination(page: try XCTUnwrap(document.page(at: 2)), at: CGPoint(x: 0, y: 800))
        root.insertChild(bookmark, at: 0)
        document.outlineRoot = root
        controller.pdfView.setMarkupDocument(document)
        controller.requestChromeRefresh(immediate: true)
        window.layoutIfNeeded()
        assertNoContentsSection()

        mode.selectedSegment = 0
        XCTAssertTrue(mode.sendAction(mode.action, to: mode.target))
        XCTAssertEqual(controller.pagesTableView.numberOfRows, 3)
        XCTAssertFalse(try XCTUnwrap(controller.pagesTableView.enclosingScrollView).isHidden)
        controller.pagesTableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertTrue(controller.pagesTableView.sendAction(controller.pagesTableView.action, to: controller.pagesTableView.target))
        XCTAssertTrue(controller.pdfView.currentPage === page)

        mode.selectedSegment = 1
        XCTAssertTrue(mode.sendAction(mode.action, to: mode.target))
        XCTAssertFalse(try XCTUnwrap(controller.bookmarksOutlineView.enclosingScrollView).isHidden)
        XCTAssertEqual(controller.bookmarksOutlineView.numberOfRows, 1)
        controller.bookmarksOutlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(controller.bookmarksOutlineView.sendAction(controller.bookmarksOutlineView.action, to: controller.bookmarksOutlineView.target))
        XCTAssertTrue(controller.pdfView.currentPage === document.page(at: 2))
        assertNoContentsSection()
        XCTAssertTrue(controller.pdfView.document === document)
        XCTAssertTrue(page.annotations.contains { $0 === annotation })
        XCTAssertEqual(annotation.contents, "Consultant annotation")
        // Navigation must leave actual rendered artwork/annotation appearances unchanged.
        for index in 0..<3 {
            XCTAssertNotNil(before[index])
            XCTAssertEqual(document.page(at: index)?.thumbnail(of: NSSize(width: 180, height: 240), for: .mediaBox).tiffRepresentation, before[index])
        }
        controller.pdfView.setMarkupDocument(nil)
        controller.requestChromeRefresh(immediate: true)
        assertNoContentsSection()
    }
}
