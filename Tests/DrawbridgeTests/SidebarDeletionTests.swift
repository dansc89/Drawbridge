import AppKit
import CoreText
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class SidebarDeletionTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-delete-\(UUID().uuidString).pdf")
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        var box = CGRect(x: 0, y: 0, width: 600, height: 400)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for number in 1...5 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 20, y: 30, width: number * 40, height: 100))
            let text = NSAttributedString(string: "ORIGINAL SHEET \(number)", attributes: [.font: NSFont.systemFont(ofSize: 22)])
            context.textPosition = CGPoint(x: 20, y: 220)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
    private func controller(_ source: URL) throws -> (MainViewController, NSWindow, PDFDocument) {
        _ = NSApplication.shared
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        let document = try XCTUnwrap(PDFDocument(url: source))
        controller.openDocumentURL = source
        controller.pdfView.setMarkupDocument(document)
        controller.pagesTableView.reloadData()
        return (controller, window, document)
    }
    private func save(_ controller: MainViewController, to source: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            controller.persistDocument(to: source, adoptAsPrimaryDocument: false, busyMessage: "Saving PDF…", showBusyOverlay: false) { continuation.resume(returning: $0) }
        }
    }
    func testBatchDeleteSaveUndoSaveAndRedoPreserveSheetsAndMarkup() async throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let (controller, window, document) = try controller(source)
        let originals = (0..<5).map { document.page(at: $0)! }
        let originalText = originals.map(\.string)
        let root = PDFOutline(); let bookmark = PDFOutline(); bookmark.label = "Deleted sheet"
        bookmark.destination = PDFDestination(page: originals[1], at: .zero); root.insertChild(bookmark, at: 0); document.outlineRoot = root
        _ = try XCTUnwrap(controller.pdfView.rectangleMarkup.create(on: originals[4], bounds: CGRect(x: 300, y: 250, width: 60, height: 50)))
        window.undoManager?.removeAllActions()
        try controller.deletePages(at: IndexSet([1, 3]))
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertNil(bookmark.destination)
        XCTAssertEqual(document.page(at: 1)?.string, originalText[2])
        let saved1 = await save(controller, to: source)
        XCTAssertTrue(saved1)
        var reopened = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(reopened.pageCount, 3)
        XCTAssertEqual((0..<3).map { reopened.page(at: $0)?.string }, [originalText[0], originalText[2], originalText[4]])
        XCTAssertEqual(RectangleMarkupRecord.capture(reopened).count, 1)
        // A subsequent light markup save must use the new, shorter baseline.
        originals[4].annotations.last?.color = .blue
        controller.markMarkupChanged()
        let saved2 = await save(controller, to: source)
        XCTAssertTrue(saved2)
        window.undoManager?.undo()
        XCTAssertEqual(document.pageCount, 5)
        XCTAssertTrue(bookmark.destination?.page === originals[1])
        let saved3 = await save(controller, to: source)
        XCTAssertTrue(saved3)
        reopened = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(reopened.pageCount, 5)
        XCTAssertEqual((0..<5).map { reopened.page(at: $0)?.string }, originalText)
        XCTAssertEqual(RectangleMarkupRecord.capture(reopened).count, 1)
        window.undoManager?.redo()
        XCTAssertEqual(document.pageCount, 3)
        let saved4 = await save(controller, to: source)
        XCTAssertTrue(saved4)
        XCTAssertEqual(PDFDocument(url: source)?.pageCount, 3)
    }
    func testPageClickRetainsSelectionAndBatchSelectionDoesNotNavigate() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let (controller, window, document) = try controller(source)
        let table = controller.pagesTableView
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        _ = table.sendAction(table.action, to: table.target)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 2))
        XCTAssertTrue(window.firstResponder === table)
        XCTAssertTrue(controller.pdfView.currentPage === document.page(at: 2))
        table.selectRowIndexes(IndexSet([0, 2, 4]), byExtendingSelection: false)
        _ = table.sendAction(table.action, to: table.target)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([0, 2, 4]))
        XCTAssertTrue(controller.pdfView.currentPage === document.page(at: 2))
        XCTAssertFalse(controller.validateMenuItem(NSMenuItem(title: "Rename", action: #selector(MainViewController.renamePageLabelFromSidebar), keyEquivalent: "")))
        controller.commandSelectAll(nil)
        XCTAssertEqual(table.selectedRowIndexes.count, 5)
        XCTAssertTrue(table.menu?.items.contains { $0.action == #selector(MainViewController.deletePagesFromSidebar) } == true)
    }
    func testDeletionCannotLeaveEmptyPDF() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let (controller, _, document) = try controller(source)
        try controller.deletePages(at: IndexSet(0..<5))
        XCTAssertEqual(document.pageCount, 5)
        XCTAssertNil(controller.pageStructureState)
    }
    func testBookmarkBatchDeletionIncludesChildrenAndUndoPreservesOrder() async throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let (controller, window, document) = try controller(source)
        let root = PDFOutline()
        var bookmarks: [PDFOutline] = []
        for number in 0..<4 {
            let bookmark = PDFOutline(); bookmark.label = "Bookmark \(number)"
            bookmark.destination = PDFDestination(page: document.page(at: number)!, at: .zero)
            root.insertChild(bookmark, at: number); bookmarks.append(bookmark)
        }
        let child = PDFOutline(); child.label = "Nested"
        child.destination = PDFDestination(page: document.page(at: 0)!, at: .zero)
        bookmarks[1].insertChild(child, at: 0)
        document.outlineRoot = root
        let outline = controller.bookmarksOutlineView
        outline.reloadData(); outline.expandItem(bookmarks[1])
        outline.selectRowIndexes(IndexSet([outline.row(forItem: bookmarks[1]), outline.row(forItem: child), outline.row(forItem: bookmarks[3])]), byExtendingSelection: false)
        window.undoManager?.removeAllActions()
        controller.deleteSelectedBookmarks(confirm: false)
        XCTAssertEqual(root.numberOfChildren, 2)
        XCTAssertEqual(root.child(at: 0)?.label, "Bookmark 0")
        XCTAssertEqual(root.child(at: 1)?.label, "Bookmark 2")
        XCTAssertEqual(document.pageCount, 5)
        let saved = await save(controller, to: source); XCTAssertTrue(saved)
        XCTAssertEqual(PDFDocument(url: source)?.outlineRoot?.numberOfChildren, 2)
        window.undoManager?.undo()
        XCTAssertEqual((0..<4).map { root.child(at: $0)?.label }, bookmarks.map(\.label))
        XCTAssertEqual(root.child(at: 1)?.numberOfChildren, 1)
        let restored = await save(controller, to: source); XCTAssertTrue(restored)
        XCTAssertEqual(PDFDocument(url: source)?.outlineRoot?.numberOfChildren, 4)
    }

    func testPageDeletionRejectsChangedSourceWithoutOverwritingIt() throws {
        let source = try fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let (controller, _, document) = try controller(source)
        try controller.deletePages(at: IndexSet([1, 3]))
        let plan = try XCTUnwrap(controller.pageStructureState?.plan(for: document))
        let stamp = try XCTUnwrap(controller.pdfView.rectangleMarkup.sourceStamp)
        var changed = try Data(contentsOf: source); changed.append(Data("\n%External change\n".utf8)); try changed.write(to: source)
        XCTAssertFalse(plan.write(document: document, currentSource: source, destination: source, expectedStamp: stamp,
                                  labels: [:], records: [], navigation: PDFTKBookmarkWriter.captureNavigation(in: document), onCommitted: { _ in XCTFail("Should not commit") }))
        XCTAssertEqual(try Data(contentsOf: source), changed)
    }

    private func previewPixels(_ page: PDFPage) throws -> Data {
        let tiff = try XCTUnwrap(page.thumbnail(of: NSSize(width: 160, height: 120), for: .mediaBox).tiffRepresentation)
        let image = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }

    func testLargeDrawingSetDeletionAndRestoration() async throws {
        guard let manifest = ProcessInfo.processInfo.environment["DRAWBRIDGE_PAGE_DELETE_CORPUS"] else {
            throw XCTSkip("Set DRAWBRIDGE_PAGE_DELETE_CORPUS to a JSON list of drawing sets")
        }
        let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        for path in paths {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent("page-delete-corpus-\(UUID().uuidString).pdf")
            try FileManager.default.copyItem(atPath: path, toPath: source.path)
            defer { try? FileManager.default.removeItem(at: source) }
            let (controller, window, document) = try controller(source)
            let originalCount = document.pageCount
            let original = try XCTUnwrap(CGPDFDocument(source as CFURL))
            let removed = IndexSet([1, 3])
            let retained = (0..<originalCount).filter { !removed.contains($0) }
            let sampleIndexes = [0, originalCount / 2, originalCount - 1].filter { !removed.contains($0) }
            let previews = try sampleIndexes.map { try previewPixels(document.page(at: $0)!) }
            window.undoManager?.removeAllActions()
            try controller.deletePages(at: removed)
            let started = Date()
            let saved = await save(controller, to: source); XCTAssertTrue(saved, path)
            print("PAGE DELETE SAVE: \(originalCount) pages, \(Date().timeIntervalSince(started))s, \(URL(fileURLWithPath: path).lastPathComponent)")
            let written = try XCTUnwrap(CGPDFDocument(source as CFURL))
            XCTAssertEqual(written.numberOfPages, originalCount - 2)
            for (outputIndex, inputIndex) in retained.enumerated() {
                let before = try XCTUnwrap(original.page(at: inputIndex + 1))
                let after = try XCTUnwrap(written.page(at: outputIndex + 1))
                XCTAssertEqual(before.rotationAngle, after.rotationAngle)
                for box in [CGPDFBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
                    XCTAssertEqual(before.getBoxRect(box), after.getBoxRect(box))
                }
            }
            let reopened = try XCTUnwrap(PDFDocument(url: source))
            XCTAssertEqual(RectangleMarkupRecord.capture(reopened), RectangleMarkupRecord.capture(document), "All retained markup geometry and styles must survive")
            for (sample, originalIndex) in sampleIndexes.enumerated() {
                let outputIndex = try XCTUnwrap(retained.firstIndex(of: originalIndex))
                let pixels = try previewPixels(reopened.page(at: outputIndex)!)
                // PDFKit's thumbnail interpolation changes slightly when a page
                // is attached to PDFView. Allow subpixel/color rounding, while
                // rejecting missing lines, displaced content, or changed colors.
                XCTAssertEqual(pixels.count, previews[sample].count)
                let differences = zip(pixels, previews[sample]).map { abs(Int($0) - Int($1)) }
                XCTAssertLessThanOrEqual(differences.max() ?? 0, 32, "Retained drawing changed visibly")
                XCTAssertLessThan(Double(differences.reduce(0, +)) / Double(max(1, differences.count)), 0.5, "Retained drawing changed visibly")

            }
            window.undoManager?.undo()
            XCTAssertEqual(document.pageCount, originalCount)
            let restored = await save(controller, to: source); XCTAssertTrue(restored, path)
            XCTAssertEqual(PDFDocument(url: source)?.pageCount, originalCount)
        }
    }

}
