import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor
final class ViewerWorkflowTests: XCTestCase {
    private func document() throws -> PDFDocument {
        let drawing = "BT /F1 12 Tf 20 160 Td (FLOOR PLAN PLAN) Tj ET\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 6 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(drawing.utf8.count) >>\nstream\n\(drawing)endstream",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 6 0 R >> >> /Contents 4 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        var bytes = Data("%PDF-1.7\n".utf8); var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: bytes))
    }
    private func pumpUntil(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(predicate(), "Async operation must finish without blocking the run loop")
    }
    func testSheetLookupRanksExactLabelsAndKeepsDuplicatePages() {
        let entries: [SheetNavigationEntry] = [
            .init(pageIndex: 0, label: "A1.10", titles: ["Étage FLOOR PLAN"]),
            .init(pageIndex: 1, label: "A1.1", titles: ["Ground floor"]),
            .init(pageIndex: 2, label: "A1.1", titles: ["Roof floor"])
        ]
        XCTAssertEqual(SheetNavigationEntry.matching(entries, query: "a1.1").map(\.pageIndex), [1, 2, 0])
        XCTAssertEqual(SheetNavigationEntry.matching(entries, query: "etage plan").map(\.pageIndex), [0])
        XCTAssertEqual(SheetNavigationEntry.matching(entries, query: "page 3").map(\.pageIndex), [2])
        XCTAssertTrue(SheetNavigationEntry.matching(entries, query: "not here").isEmpty)
        XCTAssertEqual(SheetNavigationEntry.matching(entries, query: "  "), entries)
    }
    func testSheetIndexIncludesNestedBookmarksAndUnbookmarkedPages() throws {
        let doc = try document()
        let root = PDFOutline(); let group = PDFOutline(); group.label = "Architectural"
        let child = PDFOutline(); child.label = "Roof plan"
        child.destination = PDFDestination(page: try XCTUnwrap(doc.page(at: 1)), at: .zero)
        group.insertChild(child, at: 0); root.insertChild(group, at: 0); doc.outlineRoot = root
        let entries = SheetNavigationEntry.build(document: doc, label: { "A1.\($0)" })
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].titles.isEmpty)
        XCTAssertEqual(entries[1].titles, ["Roof plan"])
    }
    func testAsyncSearchFindsMatchesAndReportsCapWithoutChangingDocument() throws {
        let fixture = try document()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("ViewerSearch-\(UUID().uuidString).pdf")
        try XCTUnwrap(fixture.dataRepresentation()).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        let doc = try XCTUnwrap(PDFDocument(url: source))
        let originalText = doc.string
        let search = PDFTextSearch(); var result: PDFTextSearch.Result?
        search.start(document: doc, query: "plan", limit: 2, progress: { _, _ in }, completion: { result = $0 })
        pumpUntil { result != nil }
        XCTAssertEqual(result?.selections.count, 2)
        XCTAssertTrue(result?.limited == true)
        XCTAssertFalse(search.isSearching)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(doc.string, originalText)
        result = nil
        search.start(document: doc, query: "floor", progress: { _, _ in }, completion: { result = $0 })
        pumpUntil { result != nil }
        XCTAssertEqual(result?.selections.count, 2)
        XCTAssertFalse(result?.limited == true)
    }
    func testRealDrawingSearchRemainsResponsive() throws {
        guard let path = ProcessInfo.processInfo.environment["DRAWBRIDGE_SEARCH_FIXTURE"] else { throw XCTSkip("Set DRAWBRIDGE_SEARCH_FIXTURE for a real drawing set") }
        let source = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: source)
        let doc = try XCTUnwrap(PDFDocument(url: source)); let search = PDFTextSearch()
        guard let word = doc.string?.split(whereSeparator: { !$0.isLetter }).first(where: { $0.count >= 4 }) else { throw XCTSkip("Fixture has no searchable PDF text; CAD geometry requires OCR") }
        let query = String(word)
        let expected = doc.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive]).count
        XCTAssertGreaterThan(expected, 0)
        var result: PDFTextSearch.Result?; var mainQueueRan = false
        let start = Date()
        search.start(document: doc, query: query, progress: { _, _ in }, completion: { result = $0 })
        let returnTime = Date().timeIntervalSince(start)
        DispatchQueue.main.async { mainQueueRan = true }
        pumpUntil { result != nil && mainQueueRan }
        XCTAssertEqual(result?.selections.count, min(1500, expected))
        XCTAssertEqual(try Data(contentsOf: source), original)
        print("async_search_start_seconds=\(returnTime) total_seconds=\(Date().timeIntervalSince(start)) matches=\(result?.selections.count ?? 0)")
    }

    func testCancelledQueryCannotDeliverStaleResults() throws {
        let doc = try document(); let search = PDFTextSearch()
        var stale = false; var finished = false
        search.start(document: doc, query: "plan", progress: { _, _ in }, completion: { _ in stale = true })
        search.cancel()
        search.start(document: doc, query: "missing", progress: { _, _ in }, completion: { result in XCTAssertTrue(result.selections.isEmpty); finished = true })
        pumpUntil { finished }
        XCTAssertFalse(stale)
        XCTAssertFalse(search.isSearching)
    }
}
