import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class PageThumbnailTests: XCTestCase {
    private func document(count: Int) -> PDFDocument {
        let document = PDFDocument()
        for index in 0..<count {
            let image = NSImage(size: NSSize(width: 200, height: 140))
            image.lockFocus()
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 200, height: 140).fill()
            NSColor.blue.setFill(); NSRect(x: 20, y: 20, width: 40 + index, height: 40).fill()
            image.unlockFocus()
            document.insert(PDFPage(image: image)!, at: index)
        }
        return document
    }

    func testSidebarCellFitsViewport() throws {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.pdfView.document = document(count: 3)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(controller.view)
        let mode = try XCTUnwrap(controls.compactMap { $0 as? NSSegmentedControl }.first { $0.label(forSegment: 0) == "Pages" })
        mode.selectedSegment = 0
        _ = mode.sendAction(mode.action, to: mode.target)
        window.contentView?.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        let table = try XCTUnwrap(controls.compactMap { $0 as? NSTableView }.first { $0.identifier?.rawValue == "pagesTable" })
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? PageThumbnailCell)
        cell.layoutSubtreeIfNeeded()
        let viewport = try XCTUnwrap(table.enclosingScrollView).contentView.bounds
        XCTAssertLessThanOrEqual(table.convert(cell.preview.bounds, from: cell.preview).maxX, viewport.width, "Thumbnail must fit the sidebar viewport")
    }

    func testVisiblePreviewRefreshesAfterAnnotationAndReusesCache() async throws {
        let document = document(count: 100)
        let page = try XCTUnwrap(document.page(at: 0))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        let cell = PageThumbnailCell(frame: NSRect(x: 0, y: 0, width: 220, height: 164))
        window.contentView = cell
        cell.configure(page: page, number: 1, label: "A1.00", current: true)
        cell.configure(page: page, number: 1, label: "MECHANICAL NOTES, SYMBOLS & LEGEND", current: true)
        cell.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(cell.preview.frame.maxX, cell.bounds.width)
        XCTAssertLessThanOrEqual(cell.caption.frame.maxX, cell.bounds.width)
        let cache = PageThumbnailCache(); cache.bind(document); cache.request(cell)
        try await Task.sleep(for: .milliseconds(150))
        let original = try XCTUnwrap(cell.preview.image?.tiffRepresentation)
        XCTAssertEqual(cache.renderedCount, 1, "Opening a preview must not render the entire drawing set")
        cache.request(cell)
        XCTAssertEqual(cache.renderedCount, 1)
        let annotation = PDFAnnotation(bounds: NSRect(x: 80, y: 30, width: 70, height: 60), forType: .square, withProperties: nil)
        annotation.color = .red; annotation.interiorColor = .red; page.addAnnotation(annotation)
        cache.invalidate(page); cache.request(cell)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(cache.renderedCount, 2)
        XCTAssertNotEqual(cell.preview.image?.tiffRepresentation, original, "Preview must include the new annotation")
    }

    func testSwitchingDocumentsDiscardsQueuedOldPages() async throws {
        let first = document(count: 2), second = document(count: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        let cell = PageThumbnailCell(frame: NSRect(x: 0, y: 0, width: 220, height: 164))
        window.contentView = cell
        let cache = PageThumbnailCache(); cache.bind(first)
        cell.configure(page: first.page(at: 0)!, number: 1, label: "Old", current: true); cache.request(cell)
        cache.bind(second)
        cell.configure(page: second.page(at: 0)!, number: 1, label: "New", current: true); cache.request(cell)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(cache.renderedCount, 1)
        XCTAssertTrue(cell.representedPage === second.page(at: 0))
        XCTAssertNotNil(cell.preview.image)
    }
}
