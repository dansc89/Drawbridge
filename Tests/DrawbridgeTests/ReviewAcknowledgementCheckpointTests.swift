import AppKit
import CryptoKit
import PDFKit
import XCTest
@testable import Drawbridge

private final class CheckpointURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "checkpoint.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                var result = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    result.append(contentsOf: bytes.prefix(count))
                }
                data = result
            }
            let append = try JSONSerialization.jsonObject(with: data ?? Data()) as! [String: Any]
            let receipt: [String: Any] = ["op": ["seq": 1, "op_type": "drawbridge.markup.v1", "payload": append["payload"]!], "duplicate": true]
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: receipt))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor final class ReviewAcknowledgementCheckpointTests: XCTestCase {
    private final class Fixture {
        let directory: URL
        let outbox: SharedReviewOutbox
        let document: SharedReviewAPI.Document
        let cache: URL
        var ids: [String] = []
        var diskCounts: [Int] = []
        var failAt: Int?
        var onAppend: ((Int) throws -> Void)?
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            cache = directory.appendingPathComponent("cache")
            let pdf = PDFDocument(); let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 200), for: .mediaBox)
            pdf.insert(page, at: 0)
            let bytes = try XCTUnwrap(pdf.dataRepresentation())
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            document = .init(id: "checkpoint", name: "Checkpoint.pdf", file_size: bytes.count, file_sha256: hash, folder_id: nil)
            let pdfCache = try XCTUnwrap(SharedReviewPDFCache(origin: URL(string: "https://checkpoint.invalid")!, instanceID: "device", document: document, directory: cache))
            try pdfCache.store(bytes)
            outbox = try SharedReviewOutbox(origin: URL(string: "https://checkpoint.invalid")!, instanceID: "device", documentID: document.id, basePDF: bytes, directory: directory.appendingPathComponent("outbox"))
            // No cache digest is available, so the fixture supplies download bytes.
            self.bytes = bytes
        }
        let bytes: Data
        func seed(_ count: Int) throws {
            try outbox.save((0..<count).map { .init(clientOpId: "op-\($0)", payload: .init(id: RectangleMarkupRecord.prefix + "\($0)", page: 0, record: nil)) })
        }
    }

    func testBoundedCheckpointsAndEndFlushThroughControllerURLProtocol() async throws {
        for count in [1, 15, 16, 17, 33] {
            let fixture = try Fixture(); try fixture.seed(count)
            try await withReview(fixture) { review, _ in
                try await self.eventually { review.syncStatus.hasPrefix("Synced") }
                XCTAssertEqual(fixture.ids, (0..<count).map { "op-\($0)" })
                XCTAssertEqual(fixture.diskCounts, (0..<count).map { count - ($0 / 16) * 16 }, "disk changes only at a bounded acknowledgement checkpoint")
                XCTAssertEqual(try fixture.outbox.load(), [])
            }
        }
    }

    func testNetworkErrorFlushesPartialBatchAndRestartPreservesOrderAndIDs() async throws {
        let fixture = try Fixture(); try fixture.seed(20); fixture.failAt = 6
        try await withReview(fixture) { review, _ in
            try await self.eventually { fixture.ids.count == 6 && review.syncStatus.contains("pending") }
            XCTAssertEqual(try fixture.outbox.load().map(\.clientOpId), (5..<20).map { "op-\($0)" })
        }
        fixture.ids = []; fixture.diskCounts = []; fixture.failAt = nil
        try await withReview(fixture, removeDirectory: false) { review, _ in
            try await self.eventually { review.syncStatus.hasPrefix("Synced") }
            XCTAssertEqual(fixture.ids, (5..<20).map { "op-\($0)" })
            XCTAssertTrue(try fixture.outbox.load().isEmpty)
        }
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    func testCloseBeforeCheckpointLeavesAcknowledgedPrefixReplayableOnDisk() async throws {
        let fixture = try Fixture(); try fixture.seed(20)
        try await withReview(fixture) { review, _ in
            fixture.onAppend = { index in
                if index == 6 { review.closeTab(at: try XCTUnwrap(review.tabURL)) }
            }
            try await self.eventually { fixture.ids.count == 6 }
            XCTAssertEqual(try fixture.outbox.load().map(\.clientOpId), (0..<20).map { "op-\($0)" })
        }
    }

    func testNewLocalEditPersistsImmediatelyDuringUncheckpointedUpload() async throws {
        let fixture = try Fixture(); try fixture.seed(20)
        try await withReview(fixture) { review, _ in
            fixture.onAppend = { index in
                if index == 4 {
                    let page = try XCTUnwrap(review.reviewPDF?.page(at: 0))
                    let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 40), forType: .square, withProperties: nil)
                    annotation.setValue(RectangleMarkupRecord.prefix + "new-local", forAnnotationKey: RectangleMarkupRecord.identityKey)
                    page.addAnnotation(annotation)
                    review.recordChanges(on: page)
                    let saved = try fixture.outbox.load()
                    XCTAssertEqual(saved.count, 18, "three acknowledgements removed plus a new edit, durably saved before its upload")
                    XCTAssertNotEqual(saved.last?.clientOpId, "op-19")
                }
            }
            try await self.eventually { review.syncStatus.hasPrefix("Synced") }
            XCTAssertEqual(fixture.ids.count, 21)
            XCTAssertTrue(try fixture.outbox.load().isEmpty)
        }
    }

    func testCheckpointWriteFailureRetainsDurableReplayAndRestartUsesSameIDs() async throws {
        let fixture = try Fixture(); try fixture.seed(20)
        let root = fixture.directory.appendingPathComponent("outbox")
        let backup = fixture.directory.appendingPathComponent("recoverable-outbox")
        try await withReview(fixture) { review, _ in
            fixture.onAppend = { index in
                if index == 16 {
                    try FileManager.default.moveItem(at: root, to: backup)
                    try Data("blocked".utf8).write(to: root)
                }
            }
            try await self.eventually { fixture.ids.count >= 16 && review.syncStatus.contains("could not be saved") }
            XCTAssertEqual(fixture.ids.count, 16, "a failed checkpoint stops the uploader")
            review.closeTab(at: try XCTUnwrap(review.tabURL))
        }
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: backup, to: root)
        XCTAssertEqual(try fixture.outbox.load().map(\.clientOpId), (0..<20).map { "op-\($0)" })
        fixture.ids = []; fixture.diskCounts = []
        try await withReview(fixture, removeDirectory: true) { review, _ in
            try await self.eventually { review.syncStatus.hasPrefix("Synced") }
            XCTAssertEqual(fixture.ids, (0..<20).map { "op-\($0)" }, "uncheckpointed acknowledgements replay with stable keys")
        }
    }

    func testSignOutDuringUploadDoesNotCheckpointInvalidatedQueue() async throws {
        let fixture = try Fixture(); try fixture.seed(20)
        try await withReview(fixture, removeDirectory: true) { review, _ in
            fixture.onAppend = { index in
                if index == 6 { NotificationCenter.default.post(name: SettingsWindowController.reviewSessionDidChange, object: nil) }
            }
            try await self.eventually { review.syncStatus.hasPrefix("Signed out") }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(fixture.ids.count, 6)
            XCTAssertEqual(try fixture.outbox.load().map(\.clientOpId), (0..<20).map { "op-\($0)" })
            XCTAssertTrue(review.retryPendingEditsSave())
            XCTAssertEqual(try fixture.outbox.load().count, 20)
        }
    }

    func testFailedLocalEditCanBeSavedAfterSignOutOnceDiskRecovers() async throws {
        let fixture = try Fixture(); try fixture.seed(20)
        let root = fixture.directory.appendingPathComponent("outbox")
        let backup = fixture.directory.appendingPathComponent("recoverable-local-outbox")
        try await withReview(fixture, removeDirectory: true) { review, _ in
            fixture.onAppend = { index in
                guard index == 4 else { return }
                try FileManager.default.moveItem(at: root, to: backup)
                try Data("blocked".utf8).write(to: root)
                let page = try XCTUnwrap(review.reviewPDF?.page(at: 0))
                let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 40), forType: .square, withProperties: nil)
                annotation.setValue(RectangleMarkupRecord.prefix + "recover-after-signout", forAnnotationKey: RectangleMarkupRecord.identityKey)
                page.addAnnotation(annotation)
                review.recordChanges(on: page)
                NotificationCenter.default.post(name: SettingsWindowController.reviewSessionDidChange, object: nil)
            }
            try await self.eventually { review.syncStatus.hasPrefix("Signed out") }
            XCTAssertFalse(review.retryPendingEditsSave(), "disk is still blocked")
            try FileManager.default.removeItem(at: root)
            try FileManager.default.moveItem(at: backup, to: root)
            XCTAssertTrue(review.retryPendingEditsSave(), "signout must not prevent local durability recovery")
            let saved = try fixture.outbox.load()
            XCTAssertTrue(saved.contains { $0.payload.id == RectangleMarkupRecord.prefix + "recover-after-signout" }, "memory-only edit must become durable after disk recovery")
            XCTAssertEqual(saved.count, 18)
            XCTAssertEqual(fixture.ids.count, 4, "local recovery must not restart a signed-out upload")
        }
    }

    private func withReview(_ fixture: Fixture, removeDirectory: Bool = false,
                            _ body: (SharedReviewWindowController, MainViewController) async throws -> Void) async throws {
        _ = NSApplication.shared
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CheckpointURLProtocol.self]
        let session = URLSession(configuration: config)
        var api = SharedReviewAPI(origin: URL(string: "https://checkpoint.invalid")!, token: "test", displayName: "Reviewer", instanceID: "device")
        api.transport = { request in
            let data: Data
            switch request.url!.path {
            case "/v1/auth/me": data = Data(#"{"reviewUsernames":true,"creatorOnlyMarkups":true,"reviewUsername":"Reviewer"}"#.utf8)
            case "/v1/documents/checkpoint/sessions": data = Data(#"{"session":{"id":"session"}}"#.utf8)
            case "/v1/documents/checkpoint/ops" where request.httpMethod == "POST":
                let append = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                fixture.ids.append(append["clientOpId"] as! String)
                fixture.diskCounts.append(try fixture.outbox.load().count)
                try fixture.onAppend?(fixture.ids.count)
                if fixture.failAt == fixture.ids.count { throw URLError(.notConnectedToInternet) }
                return try await session.data(for: request)
            case "/v1/documents/checkpoint/ops": data = Data(#"{"ops":[]}"#.utf8)
            default: data = fixture.bytes
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let editor = MainViewController()
        let review = SharedReviewWindowController(outboxDirectory: fixture.directory.appendingPathComponent("outbox"), cacheDirectory: fixture.cache)
        editor.sharedReview = review; review.editor = editor
        defer {
            fixture.onAppend = nil
            if let url = review.tabURL { review.closeTab(at: url); editor.unregisterSessionDocument(url) }
            review.window?.close(); session.invalidateAndCancel()
            if removeDirectory { try? FileManager.default.removeItem(at: fixture.directory) }
        }
        let opened = try await review.open(fixture.document, using: api, focusEditor: false)
        XCTAssertTrue(opened)
        try await body(review, editor)
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "controller did not reach expected state")
    }
}
