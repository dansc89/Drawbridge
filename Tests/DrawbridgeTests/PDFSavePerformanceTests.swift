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
        XCTAssertTrue(PDFTKBookmarkWriter.writeNavigation(in: document, to: output, pageLabels: [:]))
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
        XCTAssertTrue(PDFTKBookmarkWriter.writeNavigation(in: document, to: output, pageLabels: labels))
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let written = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(written.outlineRoot?.numberOfChildren, document.pageCount)
        XCTAssertEqual(written.outlineRoot?.child(at: document.pageCount - 1)?.label, "TEST-\(document.pageCount) - Generated Sheet")
        XCTAssertEqual(written.page(at: document.pageCount - 1)?.label, "TEST-\(document.pageCount) - Generated Sheet")
        print("generated_navigation_save_seconds=\(elapsed) pages=\(document.pageCount)")
    }
}
