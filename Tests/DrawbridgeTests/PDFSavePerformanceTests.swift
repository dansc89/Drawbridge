import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

final class PDFSavePerformanceTests: XCTestCase {
    func testPDFTKBookmarkWriterUsesLocalMetadataEngine() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_SAVE_PERF_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("Set DRAWBRIDGE_SAVE_PERF_FIXTURE to a representative PDF")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drawbridge-pdftk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("sample.pdf")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: output)
        let document = try XCTUnwrap(PDFDocument(url: output))
        let root = PDFOutline()
        let bookmark = PDFOutline()
        bookmark.label = "Fast metadata writer"
        bookmark.destination = PDFDestination(page: try XCTUnwrap(document.page(at: 0)), at: .zero)
        root.insertChild(bookmark, at: 0)
        document.outlineRoot = root
        XCTAssertEqual(PDFTKBookmarkWriter.writeNavigation(in: document, to: output, pageLabels: [:]), .saved)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: output)).outlineRoot?.child(at: 0)?.label, "Fast metadata writer")
    }

    /// Opt-in measurement against a customer drawing. The source is copied first and never changed.
    func testRealPDFSaveIsImmediatelyReadableAfterCompletion() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_SAVE_PERF_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("Set DRAWBRIDGE_SAVE_PERF_FIXTURE to a representative PDF")
        }
        let source = URL(fileURLWithPath: path)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drawbridge-save-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: output)
        let document = try XCTUnwrap(PDFDocument(url: output))
        let root = PDFOutline()
        let bookmark = PDFOutline()
        bookmark.label = "Drawbridge save verification"
        bookmark.destination = PDFDestination(page: try XCTUnwrap(document.page(at: 0)), at: .zero)
        root.insertChild(bookmark, at: 0)
        document.outlineRoot = root

        let started = CFAbsoluteTimeGetCurrent()
        XCTAssertTrue(MainViewController.writePDFDocument(document, to: output, pageLabels: [:]))
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        // Read through an independent Core Graphics consumer immediately after save returns.
        let reader = try XCTUnwrap(CGPDFDocument(output as CFURL))
        XCTAssertGreaterThan(reader.numberOfPages, 0)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: output)).outlineRoot?.child(at: 0)?.label, "Drawbridge save verification")
        print("durable_save_seconds=\(elapsed) file=\(source.lastPathComponent)")
    }

    func testGeneratedBookmarksAndPageLabelsAvoidFullPDFKitRewrite() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_SAVE_PERF_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("Set DRAWBRIDGE_SAVE_PERF_FIXTURE to a representative PDF")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drawbridge-navigation-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("generated.pdf")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: output)
        let document = try XCTUnwrap(PDFDocument(url: output))
        let root = PDFOutline()
        var labels: [Int: String] = [:]
        for index in 0..<document.pageCount {
            let title = "TEST-\(index + 1) - Generated Sheet"
            let bookmark = PDFOutline()
            bookmark.label = title
            bookmark.destination = PDFDestination(page: try XCTUnwrap(document.page(at: index)), at: .zero)
            root.insertChild(bookmark, at: index)
            labels[index] = title
        }
        document.outlineRoot = root

        let started = CFAbsoluteTimeGetCurrent()
        XCTAssertEqual(PDFTKBookmarkWriter.writeNavigation(in: document, to: output, pageLabels: labels), .saved)
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let written = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(written.outlineRoot?.numberOfChildren, document.pageCount)
        XCTAssertEqual(written.outlineRoot?.child(at: document.pageCount - 1)?.label, "TEST-\(document.pageCount) - Generated Sheet")
        XCTAssertEqual(written.page(at: document.pageCount - 1)?.label, "TEST-\(document.pageCount) - Generated Sheet")
        print("generated_navigation_save_seconds=\(elapsed) pages=\(document.pageCount)")
    }

    /// File-provider documents can be backed by a transient PDFKit URL. Navigation
    /// saves must use the original opened file when that transient URL disappears.
    func testNavigationSaveUsesExplicitOriginalWhenDocumentURLIsUnavailable() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_SAVE_PERF_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("Set DRAWBRIDGE_SAVE_PERF_FIXTURE to a representative PDF")
        }
        let source = URL(fileURLWithPath: path)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drawbridge-explicit-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transientCopy = directory.appendingPathComponent("transient.pdf")
        let output = directory.appendingPathComponent("saved.pdf")
        try FileManager.default.copyItem(at: source, to: transientCopy)
        let document = try XCTUnwrap(PDFDocument(url: transientCopy))
        let root = PDFOutline()
        let bookmark = PDFOutline()
        bookmark.label = "Explicit original source"
        bookmark.destination = PDFDestination(page: try XCTUnwrap(document.page(at: 0)), at: .zero)
        root.insertChild(bookmark, at: 0)
        document.outlineRoot = root
        let sourcePage = try XCTUnwrap(document.page(at: 0))
        let destinationPage = try XCTUnwrap(document.page(at: min(1, document.pageCount - 1)))
        let link = PDFAnnotation(bounds: NSRect(x: 24, y: 24, width: 72, height: 18), forType: .link, withProperties: nil)
        link.contents = "DrawbridgeAutoSheetLink:\(min(1, document.pageCount - 1))"
        link.action = PDFActionGoTo(destination: PDFDestination(page: destinationPage, at: .zero))
        sourcePage.addAnnotation(link)

        try FileManager.default.removeItem(at: transientCopy)
        XCTAssertEqual(PDFTKBookmarkWriter.writeNavigation(
            in: document,
            sourceURL: source,
            to: output,
            pageLabels: [0: "EXPLICIT-1"]
        ), .saved)
        let saved = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(saved.outlineRoot?.child(at: 0)?.label, "Explicit original source")
        XCTAssertEqual(saved.page(at: 0)?.label, "EXPLICIT-1")
        let savedLink = try XCTUnwrap(saved.page(at: 0)?.annotations.first {
            $0.contents?.contains("DrawbridgeAutoSheetLink") == true
        })
        XCTAssertEqual((savedLink.action as? PDFActionGoTo)?.destination.page.map(saved.index(for:)), min(1, saved.pageCount - 1))

        // Reapplying navigation must reuse the existing Drawbridge link object
        // rather than growing the PDF on every batch-link run.
        let secondOutput = directory.appendingPathComponent("saved-again.pdf")
        XCTAssertEqual(PDFTKBookmarkWriter.writeNavigation(
            in: saved,
            sourceURL: output,
            to: secondOutput,
            pageLabels: [0: "EXPLICIT-1"]
        ), .saved)
        let firstSize = try fileSize(at: output)
        let secondSize = try fileSize(at: secondOutput)
        XCTAssertLessThanOrEqual(secondSize, firstSize + 1024 * 1024)
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }
}
