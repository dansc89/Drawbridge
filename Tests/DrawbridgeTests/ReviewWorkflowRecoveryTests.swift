import AppKit
import CryptoKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class ReviewWorkflowRecoveryTests: XCTestCase {
    func testDeniedFinishRetainsNewAndExistingTextDrafts() throws {
        for existing in [false, true] {
            let pdf = PDFDocument(); let page = PDFPage(); pdf.insert(page, at: 0)
            let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 400)); view.document = pdf
            let markup = RectangleMarkupController(); markup.install(on: view); markup.bind(to: pdf)
            let annotation = existing ? markup.create(on: page, bounds: CGRect(x: 10, y: 10, width: 100, height: 50), kind: .text, text: "Original") : nil
            markup.beginTextEditing(on: page, bounds: CGRect(x: 10, y: 10, width: 100, height: 50), annotation: annotation)
            let editor = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
            editor.string = "Exact draft\nwith Unicode 🦋"
            markup.canEdit = { false }
            markup.finishTextEditing()
            XCTAssertTrue(markup.isEditingText, "access loss must not destroy an uncommittable draft")
            XCTAssertNotNil(editor.superview)
            XCTAssertEqual(editor.string, "Exact draft\nwith Unicode 🦋")
            markup.canEdit = { true }; markup.finishTextEditing(cancel: true)
        }
    }

    func testOversizedDraftIsNotSilentlyDiscarded() throws {
        let pdf = PDFDocument(); let page = PDFPage(); pdf.insert(page, at: 0)
        let view = PDFView(); view.document = pdf
        let markup = RectangleMarkupController(); markup.install(on: view); markup.bind(to: pdf)
        markup.beginTextEditing(on: page, bounds: CGRect(x: 10, y: 10, width: 100, height: 50))
        let editor = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
        editor.string = String(repeating: "a", count: 100001)
        markup.finishTextEditing()
        XCTAssertTrue(markup.isEditingText)
        XCTAssertNotNil(editor.superview)
        markup.finishTextEditing(cancel: true)
    }

    func testCacheFilesystemFailuresAreBestEffortButIntegrityIsMandatory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blocked)
        let bytes = Data("abc".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let document = SharedReviewAPI.Document(id: "d", name: "D.pdf", file_size: bytes.count, file_sha256: hash, folder_id: nil)
        let cache = try XCTUnwrap(SharedReviewPDFCache(origin: URL(string: "https://example.invalid")!, instanceID: "device", document: document, directory: blocked))
        XCTAssertNil(try cache.load())
        XCTAssertNoThrow(try cache.store(bytes), "optional cache writes must not block a verified online PDF")
        XCTAssertThrowsError(try cache.store(Data("bad".utf8)), "checksum failure must remain fatal even when cache is unavailable")
        let healthy = try XCTUnwrap(SharedReviewPDFCache(origin: URL(string: "https://example.invalid")!, instanceID: "device", document: document, directory: root.appendingPathComponent("cache")))
        try FileManager.default.createDirectory(at: healthy.file, withIntermediateDirectories: true)
        XCTAssertNil(try healthy.load(), "unreadable cache entry is a miss")
        XCTAssertNoThrow(try healthy.store(bytes))
    }
}
