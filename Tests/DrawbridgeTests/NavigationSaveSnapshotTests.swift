import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

/// Observe real outline traversal without replacing save or navigation behavior.
private final class NavigationReadDocument: PDFDocument {
    private let readLock = NSLock()
    private var workerReads = 0
    var backgroundOutlineReads: Int {
        readLock.lock(); defer { readLock.unlock() }
        return workerReads
    }
    override var outlineRoot: PDFOutline? {
        get {
            if !Thread.isMainThread {
                readLock.lock(); workerReads += 1; readLock.unlock()
            }
            return super.outlineRoot
        }
        set { super.outlineRoot = newValue }
    }
}

@MainActor
final class NavigationSaveSnapshotTests: XCTestCase {
    func testNewDestinationUsesMainThreadNavigationSnapshot() async throws {
        try await checkSave(existingDestination: false, showBusyOverlay: false)
    }
    func testBackgroundOverwriteUsesMainThreadNavigationSnapshot() async throws {
        try await checkSave(existingDestination: true, showBusyOverlay: false)
    }
    func testForegroundOverwriteUsesMainThreadNavigationSnapshot() async throws {
        try await checkSave(existingDestination: true, showBusyOverlay: true)
    }

    private func checkSave(existingDestination: Bool, showBusyOverlay: Bool) async throws {
        guard PDFTKBookmarkWriter.executableURL() != nil else { throw XCTSkip("qpdf required") }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NavigationSnapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.pdf")
        let output = existingDestination ? source : directory.appendingPathComponent("new.pdf")
        let seed = PDFDocument()
        seed.insert(PDFPage(), at: 0); seed.insert(PDFPage(), at: 1)
        XCTAssertTrue(seed.write(to: source))
        let document = try XCTUnwrap(NavigationReadDocument(url: source))
        let first = try XCTUnwrap(document.page(at: 0))
        let second = try XCTUnwrap(document.page(at: 1))
        let root = PDFOutline(); let bookmark = PDFOutline()
        bookmark.label = "Frozen navigation"
        bookmark.destination = PDFDestination(page: second, at: .zero)
        root.insertChild(bookmark, at: 0); document.outlineRoot = root
        let link = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 60, height: 20), forType: .link, withProperties: nil)
        link.contents = "DrawbridgeAutoSheetLink:1"
        link.action = PDFActionGoTo(destination: PDFDestination(page: second, at: .zero))
        first.addAnnotation(link)
        let controller = MainViewController(); _ = controller.view
        controller.pdfView.setMarkupDocument(document)
        controller.openDocumentURL = source
        XCTAssertTrue(RectangleMarkupRecord.capture(document).isEmpty, "Exercise navigation-only path")
        XCTAssertFalse(controller.pdfView.rectangleMarkup.hasUnsavedChanges)
        let saved = await withCheckedContinuation { continuation in
            controller.persistDocument(to: output, adoptAsPrimaryDocument: false, busyMessage: "Saving…", document: document, showBusyOverlay: showBusyOverlay) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(saved)
        XCTAssertEqual(document.backgroundOutlineReads, 0, "Worker must reuse captured navigation instead of traversing the live outline")
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(reopened.pageCount, 2)
        let writtenBookmark = try XCTUnwrap(reopened.outlineRoot?.child(at: 0))
        XCTAssertEqual(writtenBookmark.label, "Frozen navigation")
        XCTAssertEqual(writtenBookmark.destination?.page.map(reopened.index(for:)), 1)
        let writtenLink = try XCTUnwrap(reopened.page(at: 0)?.annotations.first { $0.contents?.contains("DrawbridgeAutoSheetLink") == true })
        XCTAssertEqual((writtenLink.action as? PDFActionGoTo)?.destination.page.map(reopened.index(for:)), 1)
    }
}
