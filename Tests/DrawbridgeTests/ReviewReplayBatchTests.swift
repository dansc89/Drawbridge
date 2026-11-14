import AppKit
import PDFKit
import CryptoKit
import XCTest
@testable import Drawbridge

@MainActor final class ReviewReplayBatchTests: XCTestCase {
    private func operation(_ seq: Int, _ id: String, page: Int = 0, text: String? = "markup", owner: String = "remote") throws -> SharedReviewAPI.Operation {
        let annotation = PDFAnnotation(bounds: CGRect(x: text == "last" || text == "updated" ? 40 : 20, y: 20, width: 70, height: 50), forType: .square, withProperties: nil)
        annotation.setValue(id, forAnnotationKey: RectangleMarkupRecord.identityKey)
        annotation.contents = text
        let record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: annotation, pageIndex: page))
        let markup = SharedReviewAPI.Markup(id: id, page: page, record: text == nil ? nil : record, ownerInstanceId: owner)
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(markup))
        return try JSONDecoder().decode(SharedReviewAPI.Operation.self, from: JSONSerialization.data(withJSONObject: ["seq": seq, "op_type": "drawbridge.markup.v1", "payload": payload]))
    }

    func testBatchCoalescesPagesAndPreservesOrderedConflictDeletionAndOwnership() async throws {
        try await withReview { review, editor in
            var refreshes: [SharedReviewWindowController.ReplayRefresh] = []
            review.replayRefreshObserver = { refreshes.append($0) }
            let a = RectangleMarkupRecord.prefix + "a", b = RectangleMarkupRecord.prefix + "b"
            let c = RectangleMarkupRecord.prefix + "c"
            try review.replayOperations([
                self.operation(1, a, text: "first"), self.operation(2, a, text: "last"),
                self.operation(3, b), self.operation(4, b, text: nil),
                self.operation(5, c, page: 1, owner: "device")
            ], instanceID: "device")
            let page = try XCTUnwrap(review.reviewPDF?.page(at: 0))
            XCTAssertEqual(page.annotations.count, 1)
            XCTAssertEqual(page.annotations.first?.bounds.minX, 40)
            XCTAssertEqual(RectangleMarkupRecord.identity(try XCTUnwrap(page.annotations.first)), a)
            XCTAssertTrue(try XCTUnwrap(page.annotations.first).isReadOnly)
            XCTAssertFalse(try XCTUnwrap(review.reviewPDF?.page(at: 1)?.annotations.first).isReadOnly)
            XCTAssertEqual(review.revision, 5)
            XCTAssertTrue(editor.pdfView.document === review.reviewPDF)
            XCTAssertEqual(refreshes, [.page(0), .page(1), .selectionAndList])
            refreshes.removeAll()
            try review.replayOperations([self.operation(6, c, page: 1, owner: "device")], instanceID: "device")
            XCTAssertTrue(refreshes.isEmpty, "an identical owned echo does not invalidate UI")
        }
    }

    func testPendingLocalUpdateShieldsRemoteUpdatesAndDeletionWithoutRefreshing() async throws {
        try await withReview { review, _ in
            let id = RectangleMarkupRecord.prefix + "pending-update"
            try review.replayOperations([self.operation(1, id, owner: "device")], instanceID: "device")
            let page = try XCTUnwrap(review.reviewPDF?.page(at: 0))
            let local = try XCTUnwrap(page.annotations.first)
            local.bounds = CGRect(x: 90, y: 35, width: 100, height: 60)
            local.contents = "unsent local update"
            review.recordChanges(on: page)
            let expected = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: local, pageIndex: 0))

            var refreshes: [SharedReviewWindowController.ReplayRefresh] = []
            review.replayRefreshObserver = { refreshes.append($0) }
            // recordChanges queues a real outbox edit. The synchronous replay below
            // cannot yield to the sync task and acknowledge that edit first.
            try review.replayOperations([
                self.operation(2, id, text: "updated"),
                self.operation(3, id, text: nil),
                self.operation(4, id, text: "last", owner: "device")
            ], instanceID: "device")

            XCTAssertEqual(review.revision, 4, "shielded operations still advance the replay cursor")
            XCTAssertEqual(page.annotations.count, 1)
            XCTAssertTrue(page.annotations.first === local, "pending markup must not be replaced")
            XCTAssertEqual(RectangleMarkupRecord.capture(annotation: local, pageIndex: 0), expected)
            XCTAssertFalse(local.isReadOnly, "a remote conflict must not change local ownership")
            XCTAssertTrue(refreshes.isEmpty, "a fully shielded batch must not invalidate pages or selection/list UI")
        }
    }

    func testPendingLocalDeletionStaysDeletedWhileUnrelatedBatchEditsRefreshOnce() async throws {
        try await withReview { review, _ in
            let deletedID = RectangleMarkupRecord.prefix + "pending-delete"
            let remoteID = RectangleMarkupRecord.prefix + "unrelated"
            try review.replayOperations([self.operation(1, deletedID, owner: "device")], instanceID: "device")
            let page = try XCTUnwrap(review.reviewPDF?.page(at: 0))
            page.removeAnnotation(try XCTUnwrap(page.annotations.first))
            review.recordChanges(on: page)

            var refreshes: [SharedReviewWindowController.ReplayRefresh] = []
            review.replayRefreshObserver = { refreshes.append($0) }
            try review.replayOperations([
                self.operation(2, deletedID, text: "updated"),
                self.operation(3, remoteID, page: 1, text: "first"),
                self.operation(4, deletedID, text: nil),
                self.operation(5, remoteID, page: 1, text: "last"),
                self.operation(6, deletedID, owner: "device")
            ], instanceID: "device")

            XCTAssertEqual(review.revision, 6)
            XCTAssertTrue(page.annotations.isEmpty, "remote updates and owned echoes must not resurrect a pending deletion")
            let remotePage = try XCTUnwrap(review.reviewPDF?.page(at: 1))
            XCTAssertEqual(remotePage.annotations.count, 1)
            let remote = try XCTUnwrap(remotePage.annotations.first)
            XCTAssertEqual(RectangleMarkupRecord.identity(remote), remoteID)
            XCTAssertEqual(remote.bounds.minX, 40, "unrelated operations retain their replay order")
            XCTAssertTrue(remote.isReadOnly)
            XCTAssertEqual(refreshes, [.page(1), .selectionAndList],
                           "only the unrelated changed page refreshes, once for the entire batch")
        }
    }

    func testPartialFailureFlushesAppliedPagesAndDoesNotAdvancePastFailure() async throws {
        try await withReview { review, _ in
            var refreshes: [SharedReviewWindowController.ReplayRefresh] = []
            review.replayRefreshObserver = { refreshes.append($0) }
            let id = RectangleMarkupRecord.prefix + "partial"
            XCTAssertThrowsError(try review.replayOperations([
                self.operation(1, id), self.operation(2, id, text: "updated"),
                self.operation(3, id, page: 99), self.operation(4, id, text: nil)
            ], instanceID: "device"))
            XCTAssertEqual(review.revision, 2)
            XCTAssertEqual(review.reviewPDF?.page(at: 0)?.annotations.first?.bounds.minX, 40)
            XCTAssertEqual(refreshes, [.page(0), .selectionAndList])
            refreshes.removeAll()
            try review.replayOperations([self.operation(3, id, text: nil)], instanceID: "device")
            XCTAssertEqual(review.reviewPDF?.page(at: 0)?.annotations.count, 0)
            XCTAssertEqual(refreshes, [.page(0), .selectionAndList])
        }
    }

    func testEmptyBatchAndInvalidatedLifecycleDoNotRefreshOrMutate() async throws {
        try await withReview { review, _ in
            var refreshes: [SharedReviewWindowController.ReplayRefresh] = []
            review.replayRefreshObserver = { refreshes.append($0) }
            try review.replayOperations([], instanceID: "device")
            NotificationCenter.default.post(name: SettingsWindowController.reviewSessionDidChange, object: nil)
            XCTAssertThrowsError(try review.replayOperations([self.operation(1, RectangleMarkupRecord.prefix + "late")], instanceID: "device"))
            XCTAssertEqual(review.revision, 0)
            XCTAssertTrue(refreshes.isEmpty)
        }
    }

    private func withReview(_ body: (SharedReviewWindowController, MainViewController) throws -> Void) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = PDFDocument()
        for index in 0..<2 {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 200), for: .mediaBox)
            pdf.insert(page, at: index)
        }
        let bytes = try XCTUnwrap(pdf.dataRepresentation())
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let document = SharedReviewAPI.Document(id: "replay", name: "Replay.pdf", file_size: bytes.count, file_sha256: hash, folder_id: nil)
        let origin = URL(string: "https://offline.invalid")!
        let cache = try XCTUnwrap(SharedReviewPDFCache(origin: origin, instanceID: "device", document: document, directory: directory.appendingPathComponent("cache")))
        try cache.store(bytes)
        var api = SharedReviewAPI(origin: URL(string: "https://offline.invalid")!, token: "test", displayName: "Reviewer", instanceID: "device")
        api.transport = { request in
            let data: Data
            switch request.url!.path {
            case "/v1/auth/me": data = Data(#"{"reviewUsernames":true,"creatorOnlyMarkups":true,"reviewUsername":"Reviewer"}"#.utf8)
            case "/v1/documents/replay/sessions": data = Data(#"{"session":{"id":"session"}}"#.utf8)
            case "/v1/documents/replay/ops": data = Data(#"{"ops":[]}"#.utf8)
            default: data = bytes
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let editor = MainViewController()
        let review = SharedReviewWindowController(outboxDirectory: directory.appendingPathComponent("outbox"), cacheDirectory: directory.appendingPathComponent("cache"))
        editor.sharedReview = review
        review.editor = editor
        defer {
            if let url = review.tabURL { review.closeTab(at: url); editor.unregisterSessionDocument(url) }
            review.window?.close()
        }
        let opened = try await review.open(document, using: api, focusEditor: false)
        XCTAssertTrue(opened)
        // No suspension during assertions/replay: the background empty poll cannot race revision checks.
        try body(review, editor)
    }
}
