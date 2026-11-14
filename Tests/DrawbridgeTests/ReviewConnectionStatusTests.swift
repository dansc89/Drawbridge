import AppKit
import CryptoKit
import PDFKit
import XCTest
@testable import Drawbridge

@MainActor final class ReviewConnectionStatusTests: XCTestCase {
    func testConnectionStartsOfflineAndExpiresWithoutAnotherPoll() {
        var connection = ReviewSyncConnection()
        XCTAssertFalse(connection.isOnline(at: 100))
        connection.receivedResponse(at: 100)
        XCTAssertTrue(connection.isOnline(at: 100))
        XCTAssertTrue(connection.isOnline(at: 104.99))
        XCTAssertFalse(connection.isOnline(at: 105))
        XCTAssertFalse(connection.isOnline(at: 99), "a backwards clock must fail closed")
    }

    func testFailureClearsFreshResponseAndRecoveryRequiresAnotherResponse() {
        var connection = ReviewSyncConnection()
        connection.receivedResponse(at: 100)
        connection.disconnect()
        XCTAssertFalse(connection.isOnline(at: 101))
        connection.receivedResponse(at: 102)
        XCTAssertTrue(connection.isOnline(at: 102))
        connection.disconnect()
        XCTAssertFalse(connection.isOnline(at: 102))
    }

    func testReviewHeaderKeepsSavingSeparateFromConnectionAndReservesFarRight() {
        let pane = PDFPaneContainerView(pdfView: MarkupPDFView(frame: .zero))
        pane.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        pane.updateHeader(documentName: "Drawing.pdf", side: "Left", active: true, split: false,
                          reviewStatus: "Saving… · 2 pending", reviewOnline: true)
        pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.modeLabel.stringValue, "Saving… · 2 pending")
        XCTAssertEqual(pane.connectionLabel.stringValue, "Online")
        XCTAssertNotNil(pane.connectionIcon.image)
        XCTAssertFalse(pane.connectionStatus.isHidden)
        XCTAssertTrue(pane.closeButton.isHidden)
        XCTAssertGreaterThanOrEqual(pane.connectionStatus.frame.minX, pane.modeLabel.frame.maxX)
        XCTAssertEqual(pane.connectionStatus.frame.maxX, pane.header.bounds.maxX - 10, accuracy: 1)
        XCTAssertTrue(pane.header.accessibilityLabel()?.contains("Online") == true)
        XCTAssertTrue(pane.connectionStatus.toolTip?.contains("durable") == true)
    }

    func testTwoHeadersCanShowIndependentConnectionStatesAndLocalPDFHidesBadge() {
        let left = PDFPaneContainerView(pdfView: MarkupPDFView(frame: .zero))
        let right = PDFPaneContainerView(pdfView: MarkupPDFView(frame: .zero))
        left.updateHeader(documentName: "A.pdf", side: "Left", active: true, split: true,
                          reviewStatus: "Synced · Revision 13", reviewOnline: true)
        right.updateHeader(documentName: "B.pdf", side: "Right", active: false, split: true,
                           reviewStatus: "Synced · Revision 7", reviewOnline: false)
        XCTAssertEqual(left.connectionLabel.stringValue, "Online")
        XCTAssertEqual(right.connectionLabel.stringValue, "Offline")
        XCTAssertEqual(right.modeLabel.stringValue, "Synced · Revision 7", "last sync is not current connectivity")
        XCTAssertFalse(right.closeButton.isHidden)
        right.updateHeader(documentName: "Local.pdf", side: "Right", active: false, split: true)
        XCTAssertTrue(right.connectionStatus.isHidden)
        XCTAssertFalse(right.header.isHidden)
    }

    func testAuthenticatedPollFailuresAndRecoveryDoNotDependOnSocketOrOutbox() async throws {
        try await withReview { review, _, fixture in
            XCTAssertFalse(review.reviewIsOnline, "session creation/socket allocation are not a sync response")
            fixture.releaseInitialPoll = true
            try await self.eventually { review.reviewIsOnline && review.syncStatus.hasPrefix("Synced") }
            XCTAssertTrue(fixture.authenticatedOps)
            // A clean outbox does not imply Online. Every unsuccessful sync response fails closed.
            for code in [401, 403, 500] {
                fixture.statusCode = code
                try await self.eventually { !review.reviewIsOnline }
                fixture.statusCode = 200
                try await self.eventually { review.reviewIsOnline }
            }
            fixture.networkFailure = true
            try await self.eventually { !review.reviewIsOnline }
            fixture.networkFailure = false
            try await self.eventually { review.reviewIsOnline }
            review.closeTab(at: try XCTUnwrap(review.tabURL))
            XCTAssertFalse(review.reviewIsOnline)
        }
    }

    func testHungPollExpiresOnlineWithoutChangingLastSyncedState() async throws {
        try await withReview { review, _, fixture in
            fixture.releaseInitialPoll = true
            try await self.eventually { review.reviewIsOnline && review.syncStatus.hasPrefix("Synced") }
            let lastSync = review.syncStatus
            fixture.releaseInitialPoll = false
            try await self.eventually(timeout: 7) { !review.reviewIsOnline }
            XCTAssertEqual(review.syncStatus, lastSync)
        }
    }

    func testSessionTeardownRejectsDelayedSuccessfulPoll() async throws {
        try await withReview { review, _, fixture in
            try await self.eventually { fixture.pollEntered }
            NotificationCenter.default.post(name: SettingsWindowController.reviewSessionDidChange, object: nil)
            fixture.releaseInitialPoll = true
            for _ in 0..<100 { await Task.yield() }
            XCTAssertFalse(review.reviewIsOnline)
            XCTAssertTrue(review.syncStatus.hasPrefix("Signed out"))
        }
    }

    func testOnlineCanStillHavePendingEditsAndRejectedAppendRetriesSameOutboxOperation() async throws {
        try await withReview { review, editor, fixture in
            fixture.releaseInitialPoll = true
            try await self.eventually { review.reviewIsOnline && review.canEdit }
            fixture.releaseAppend = false
            fixture.appendCode = 500
            let page = try XCTUnwrap(editor.pdfView.document?.page(at: 0))
            let annotation = try XCTUnwrap(editor.pdfView.rectangleMarkup.create(
                on: page, bounds: CGRect(x: 20, y: 20, width: 70, height: 50)))
            XCTAssertNotNil(RectangleMarkupRecord.identity(annotation))
            // Explicit capture is harmless if the real mutation callback already captured it.
            review.recordChanges(on: page)
            try await self.eventually { !fixture.appendIDs.isEmpty }
            XCTAssertTrue(review.reviewIsOnline, "a blocked append is not an acknowledgement; prior poll is still fresh")
            XCTAssertTrue(review.syncStatus.contains("pending"))
            fixture.releaseAppend = true
            try await self.eventually { !review.reviewIsOnline }
            XCTAssertTrue(review.syncStatus.contains("pending"))
            fixture.appendCode = 200
            try await self.eventually { review.reviewIsOnline && review.syncStatus.hasPrefix("Synced") }
            XCTAssertGreaterThanOrEqual(fixture.appendIDs.count, 2)
            XCTAssertEqual(Set(fixture.appendIDs).count, 1, "a rejected append must retain its original idempotency key")
        }
    }

    private final class Fixture {
        var releaseAppend = true
        var appendCode = 200
        var appendIDs: [String] = []
        var releaseInitialPoll = false
        var pollEntered = false
        var authenticatedOps = false
        var statusCode = 200
        var networkFailure = false
    }

    private func withReview(_ body: (SharedReviewWindowController, MainViewController, Fixture) async throws -> Void) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = URL(string: "https://offline.invalid")!
        let pdf = PDFDocument()
        let page = PDFPage()
        page.setBounds(NSRect(x: 0, y: 0, width: 300, height: 200), for: .mediaBox)
        pdf.insert(page, at: 0)
        let bytes = try XCTUnwrap(pdf.dataRepresentation())
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let document = SharedReviewAPI.Document(id: "document", name: "Drawing.pdf", file_size: bytes.count,
                                                file_sha256: hash, folder_id: nil)
        let cache = try XCTUnwrap(SharedReviewPDFCache(origin: origin, instanceID: "device", document: document,
                                                      directory: directory.appendingPathComponent("cache")))
        try cache.store(bytes)
        let fixture = Fixture()
        var api = SharedReviewAPI(origin: origin, token: "offline-test-token", displayName: "Reviewer", instanceID: "device")
        api.transport = { request in
            let path = request.url!.path
            let text: String
            var code = 200
            switch path {
            case "/v1/auth/me":
                text = #"{"reviewUsernames":true,"creatorOnlyMarkups":true,"reviewUsername":"Reviewer"}"#
            case "/v1/documents/document/sessions": text = #"{"session":{"id":"session"}}"#
            case "/v1/documents/document/ops":
                if request.httpMethod == "POST" {
                    let append = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
                    fixture.appendIDs.append(try XCTUnwrap(append["clientOpId"] as? String))
                    while !fixture.releaseAppend { await Task.yield() }
                    code = fixture.appendCode
                    let receipt: [String: Any] = ["op": ["seq": 1, "op_type": "drawbridge.markup.v1",
                                                         "payload": try XCTUnwrap(append["payload"])]]
                    let data = try JSONSerialization.data(withJSONObject: receipt)
                    return (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
                }
                fixture.pollEntered = true
                while !fixture.releaseInitialPoll { await Task.yield() }
                fixture.authenticatedOps = request.value(forHTTPHeaderField: "Authorization") == "Bearer offline-test-token"
                if fixture.networkFailure { throw URLError(.notConnectedToInternet) }
                code = fixture.statusCode
                text = #"{"ops":[]}"#
            default: throw SharedReviewError("Unexpected offline fixture request: \(path)")
            }
            return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
        let editor = MainViewController()
        let review = SharedReviewWindowController(outboxDirectory: directory.appendingPathComponent("outbox"),
                                                  cacheDirectory: directory.appendingPathComponent("cache"))
        editor.sharedReview = review
        review.editor = editor
        defer {
            fixture.releaseInitialPoll = true
            fixture.releaseAppend = true
            if let url = review.tabURL { review.closeTab(at: url); editor.unregisterSessionDocument(url) }
            review.window?.close()
        }
        let opened = try await review.open(document, using: api, focusEditor: false)
        XCTAssertTrue(opened)
        try await body(review, editor, fixture)
    }

    private func eventually(timeout: TimeInterval = 3, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "Review state did not reach the expected value before the deadline")
    }
}
