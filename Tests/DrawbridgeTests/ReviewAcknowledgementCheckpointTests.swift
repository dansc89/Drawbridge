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
        var opsStatus = 200
        var presenceJoins = 0
        var presenceLeaves = 0
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

    func testSignoutCheckpointsFocusedNewAndExistingTextWithoutTransport() async throws {
        for existing in [false, true] {
            let fixture = try Fixture()
            try await withReview(fixture, removeDirectory: true) { review, editor in
                try await self.eventually { review.canEdit }
                let markup = editor.pdfView.rectangleMarkup
                let page = try XCTUnwrap(review.reviewPDF?.page(at: 0))
                let bounds = CGRect(x: 10, y: 10, width: 120, height: 60)
                let annotation = existing ? markup.create(on: page, bounds: bounds, kind: .text, text: "Before") : nil
                markup.beginTextEditing(on: page, bounds: bounds, annotation: annotation)
                let textView = try XCTUnwrap(editor.pdfView.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
                textView.string = "Unsent exact text\n🦋"
                let requests = fixture.ids.count
                review.perform(NSSelectorFromString("reviewSessionChanged"))
                XCTAssertFalse(review.canEdit)
                XCTAssertFalse(markup.isEditingText)
                XCTAssertTrue(try fixture.outbox.load().contains { $0.payload.record?.text == "Unsent exact text\n🦋" })
                XCTAssertTrue(review.canCloseReview())
                for _ in 0..<20 { await Task.yield() }
                XCTAssertEqual(fixture.ids.count, requests)
                review.closeTab(at: try XCTUnwrap(review.tabURL))
                XCTAssertTrue(try fixture.outbox.load().contains { $0.payload.record?.text == "Unsent exact text\n🦋" })
            }
        }
    }

    func testAccessLossCheckpointsActiveTextBeforeDisablingEdits() async throws {
        let fixture = try Fixture()
        try await withReview(fixture, removeDirectory: true) { review, editor in
            try await self.eventually { review.canEdit }
            let page = try XCTUnwrap(review.reviewPDF?.page(at: 0))
            editor.pdfView.rectangleMarkup.beginTextEditing(on: page, bounds: CGRect(x: 10, y: 10, width: 120, height: 60))
            let text = try XCTUnwrap(editor.pdfView.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
            text.string = "Access ended draft\n🦋"
            fixture.opsStatus = 403
            try await eventually { !review.canEdit }
            XCTAssertFalse(editor.pdfView.rectangleMarkup.isEditingText)
            XCTAssertEqual(try fixture.outbox.load().first?.payload.record?.text, "Access ended draft\n🦋")
            XCTAssertTrue(fixture.ids.isEmpty)
            XCTAssertTrue(review.canCloseReview())
        }
    }

    func testSignoutCheckpointsInactiveSecondaryPaneText() async throws {
        let fixture = try Fixture()
        try await withReview(fixture, removeDirectory: true) { review, editor in
            try await self.eventually { review.canEdit }
            let secondary = MarkupPDFView(frame: editor.pdfView.frame)
            secondary.setMarkupDocument(review.reviewPDF)
            editor.secondaryPDFView = secondary
            secondary.rectangleMarkup.canEdit = { [weak review] in review?.canEdit == true }
            secondary.rectangleMarkup.onMutation = { [weak review] in review?.recordChanges(on: $0) }
            let page = try XCTUnwrap(review.reviewPDF?.page(at: 0))
            secondary.rectangleMarkup.beginTextEditing(on: page, bounds: CGRect(x: 10, y: 10, width: 120, height: 60))
            let text = try XCTUnwrap(secondary.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
            text.string = "Inactive pane draft"
            review.perform(NSSelectorFromString("reviewSessionChanged"))
            XCTAssertFalse(secondary.rectangleMarkup.isEditingText)
            XCTAssertEqual(try fixture.outbox.load().first?.payload.record?.text, "Inactive pane draft")
            XCTAssertTrue(fixture.ids.isEmpty)
        }
    }

    func testClosedTabDeletionChecksDurableQueueAndMalformedRecovery() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let browser = SharedReviewWindowController(outboxDirectory: fixture.directory.appendingPathComponent("outbox"))
        let api = SharedReviewAPI(origin: URL(string: "https://checkpoint.invalid")!, token: "test", displayName: "Reviewer", instanceID: "device")
        XCTAssertNoThrow(try browser.ensureDeletionSafe([fixture.document], api: api))
        try fixture.seed(1)
        XCTAssertThrowsError(try browser.ensureDeletionSafe([fixture.document], api: api))
        let restarted = SharedReviewWindowController(outboxDirectory: fixture.directory.appendingPathComponent("outbox"))
        XCTAssertThrowsError(try restarted.ensureDeletionSafe([fixture.document], api: api))
        try fixture.outbox.save([])
        XCTAssertNoThrow(try restarted.ensureDeletionSafe([fixture.document], api: api))
        let files = try FileManager.default.contentsOfDirectory(at: fixture.directory.appendingPathComponent("outbox"), includingPropertiesForKeys: nil)
        try Data("malformed".utf8).write(to: XCTUnwrap(files.first))
        XCTAssertThrowsError(try restarted.ensureDeletionSafe([fixture.document], api: api))
        XCTAssertTrue(fixture.ids.isEmpty)
    }

    func testBlockedCloseAndQuitExplainFailureAndRetryAfterDiskRecovery() async throws {
        let fixture = try Fixture()
        try await withReview(fixture, removeDirectory: true) { review, editor in
            try await self.eventually { review.canEdit }
            let directory = fixture.directory.appendingPathComponent("outbox")
            let backup = fixture.directory.appendingPathComponent("saved-outbox")
            try FileManager.default.moveItem(at: directory, to: backup)
            try Data("blocked".utf8).write(to: directory)
            let markup = editor.pdfView.rectangleMarkup
            let page = try XCTUnwrap(review.reviewPDF?.page(at: 0))
            markup.beginTextEditing(on: page, bounds: CGRect(x: 10, y: 10, width: 120, height: 60))
            let textView = try XCTUnwrap(editor.pdfView.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
            textView.string = "Retain on failure"
            review.perform(NSSelectorFromString("reviewSessionChanged"))
            XCTAssertFalse(review.canCloseReview())
            XCTAssertFalse(review.canQuit())
            XCTAssertTrue(review.closeBlockExplanation.contains("Checkpoint.pdf"))
            XCTAssertTrue(review.closeBlockExplanation.contains("permissions"))
            XCTAssertTrue(review.closeBlockExplanation.contains("already saved locally"))
            let tab = try XCTUnwrap(review.tabURL)
            editor.closeDocumentTab(at: tab)
            editor.commandCloseDocument(nil)
            XCTAssertEqual(review.tabURL, tab)
            XCTAssertTrue(review.hasPendingChanges)
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.moveItem(at: backup, to: directory)
            XCTAssertTrue(review.canCloseReview())
            XCTAssertTrue(review.canQuit())
            XCTAssertTrue(try fixture.outbox.load().contains { $0.payload.record?.text == "Retain on failure" })
        }
    }

    func testBrowserPresenceLivesUntilHiddenFinalReviewClosesAndRestartsOnReopen() async throws {
        let fixture = try Fixture()
        let active = SettingsWindowController.activeReviewSession
        let attempted = SettingsWindowController.attemptedSessionRestore
        SettingsWindowController.attemptedSessionRestore = true
        SettingsWindowController.activeReviewSession = (URL(string: "https://checkpoint.invalid")!, .init(token: "test", instanceId: "device", displayName: "Reviewer"))
        defer {
            SettingsWindowController.activeReviewSession = active
            SettingsWindowController.attemptedSessionRestore = attempted
            UserDefaults.standard.removeObject(forKey: "DrawbridgeReviewFolder|https://checkpoint.invalid|device|workspace")
        }
        try await withReview(fixture, removeDirectory: true) { review, _ in
            review.buildWindow()
            review.showWindow(nil)
            try await review.loadDocuments()
            try await self.eventually { fixture.presenceJoins == 1 }
            review.window?.close()
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(fixture.presenceLeaves, 0, "browser close must not retire a lease while a Review PDF remains open")
            review.closeTab(at: try XCTUnwrap(review.tabURL))
            try await self.eventually { fixture.presenceLeaves == 1 }
            review.showReviews(nil)
            try await self.eventually { fixture.presenceJoins == 2 }
            review.window?.close()
            try await self.eventually { fixture.presenceLeaves == 2 }
        }
    }

    func testEditorHandoffAndAdditionalReviewKeepPresenceUntilFinalHiddenTabCloses() async throws {
        let fixture = try Fixture()
        let active = SettingsWindowController.activeReviewSession
        let attempted = SettingsWindowController.attemptedSessionRestore
        SettingsWindowController.attemptedSessionRestore = true
        SettingsWindowController.activeReviewSession = (URL(string: "https://checkpoint.invalid")!, .init(token: "test", instanceId: "device", displayName: "Reviewer"))
        defer {
            SettingsWindowController.activeReviewSession = active
            SettingsWindowController.attemptedSessionRestore = attempted
            UserDefaults.standard.removeObject(forKey: "DrawbridgeReviewFolder|https://checkpoint.invalid|device|workspace")
        }
        try await withReview(fixture, removeDirectory: true) { review, _ in
            review.showWindow(nil)
            try await review.loadDocuments()
            try await self.eventually { fixture.presenceJoins == 1 }
            let first = try XCTUnwrap(review.tabURL)
            let second = SharedReviewAPI.Document(id: "second", name: "Second.pdf", file_size: fixture.document.file_size, file_sha256: fixture.document.file_sha256, folder_id: nil)
            // Downloads use URLSession's file API, not the JSON transport seam.
            let secondCache = try XCTUnwrap(SharedReviewPDFCache(origin: URL(string: "https://checkpoint.invalid")!, instanceID: "device", document: second, directory: fixture.cache))
            try secondCache.store(fixture.bytes)
            let opened = try await review.open(second, focusEditor: true)
            XCTAssertTrue(opened)
            XCTAssertFalse(try XCTUnwrap(review.window).isVisible)
            let child = try XCTUnwrap(review.review(for: try XCTUnwrap(review.editor?.pdfView.document)))
            let secondURL = try XCTUnwrap(child.tabURL)
            XCTAssertNotEqual(first, secondURL)
            review.closeTab(at: first)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(fixture.presenceLeaves, 0)
            review.closeTab(at: secondURL)
            try await self.eventually { fixture.presenceLeaves == 1 }
        }
    }

    func testIncomingDeletionCannotDetachInactiveSecondaryTextEditor() async throws {
        let fixture = try Fixture()
        try await withReview(fixture, removeDirectory: true) { review, editor in
            try await self.eventually { review.canEdit }
            let secondary = MarkupPDFView(frame: editor.pdfView.frame)
            secondary.setMarkupDocument(review.reviewPDF)
            editor.secondaryPDFView = secondary
            secondary.rectangleMarkup.canEdit = { review.canEdit }
            let page = try XCTUnwrap(review.reviewPDF?.page(at: 0))
            let annotation = try XCTUnwrap(secondary.rectangleMarkup.create(on: page, bounds: CGRect(x: 10, y: 10, width: 120, height: 60), kind: .text, text: "Before"))
            let id = RectangleMarkupRecord.prefix + "editing-secondary"
            annotation.setValue(id, forAnnotationKey: RectangleMarkupRecord.identityKey)

            secondary.rectangleMarkup.beginTextEditing(on: page, bounds: annotation.bounds, annotation: annotation)
            let text = try XCTUnwrap(secondary.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
            text.string = "Exact local draft 🦋"
            let markup = SharedReviewAPI.Markup(id: id, page: 0, record: nil, ownerInstanceId: "remote")
            let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(markup))
            let operation = try JSONDecoder().decode(SharedReviewAPI.Operation.self, from: JSONSerialization.data(withJSONObject: ["seq": 1, "op_type": "drawbridge.markup.v1", "payload": payload]))
            XCTAssertThrowsError(try review.replayOperations([operation], instanceID: "device"))
            XCTAssertTrue(annotation.page === page)
            XCTAssertEqual(review.revision, 0)
            XCTAssertEqual(secondary.rectangleMarkup.textDraftRecovery?.text, "Exact local draft 🦋")
            secondary.rectangleMarkup.finishTextEditing(cancel: true)
            try review.replayOperations([operation], instanceID: "device")
            XCTAssertNil(annotation.page)
            XCTAssertEqual(review.revision, 1)
        }
    }

    func testOversizedDraftCannotBeOverwrittenAndSurvivesDocumentSwitch() async throws {
        let fixture = try Fixture()
        try await withReview(fixture, removeDirectory: true) { review, editor in
            try await self.eventually { review.canEdit }
            let viewer = editor.pdfView, markup = viewer.rectangleMarkup
            let original = try XCTUnwrap(review.reviewPDF)
            let page = try XCTUnwrap(original.page(at: 0))
            let bounds = CGRect(x: 10, y: 10, width: 120, height: 60)
            markup.beginTextEditing(on: page, bounds: bounds)
            let text = try XCTUnwrap(viewer.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
            let exact = String(repeating: "🦋", count: 25001)
            text.string = exact
            markup.beginTextEditing(on: page, bounds: bounds.offsetBy(dx: 20, dy: 20))
            XCTAssertEqual(markup.textDraftRecovery?.text, exact)
            XCTAssertEqual(viewer.subviews.compactMap { $0 as? MarkupInlineTextView }.count, 1)
            let other = PDFDocument(); other.insert(PDFPage(), at: 0)
            viewer.setMarkupDocument(other)
            XCTAssertFalse(review.canCloseReview(), "a suspended oversized draft must still block close")
            viewer.setMarkupDocument(original)
            XCTAssertEqual(markup.textDraftRecovery?.text, exact)
            let restored = try XCTUnwrap(viewer.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
            restored.string = "Corrected draft"
            XCTAssertTrue(review.canCloseReview())
            XCTAssertEqual(try fixture.outbox.load().last?.payload.record?.text, "Corrected draft")
        }
    }

    func testCorrectingRetainedOversizedDraftUnblocksCloseAndQuit() async throws {
        let fixture = try Fixture()
        try await withReview(fixture, removeDirectory: true) { review, editor in
            try await self.eventually { review.canEdit }
            let page = try XCTUnwrap(review.reviewPDF?.page(at: 0))
            editor.pdfView.rectangleMarkup.beginTextEditing(on: page, bounds: CGRect(x: 10, y: 10, width: 120, height: 60))
            let text = try XCTUnwrap(editor.pdfView.subviews.compactMap { $0 as? MarkupInlineTextView }.first)
            text.string = String(repeating: "x", count: 100001)
            XCTAssertFalse(review.canCloseReview())
            text.string = "Repaired"
            XCTAssertTrue(review.canCloseReview(), "a superseded recovery snapshot must not permanently block close")
            XCTAssertTrue(review.canQuit())
            XCTAssertFalse(review.hasPendingChanges)
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
            case "/v1/projects": data = Data(#"{"projects":[{"id":"workspace","name":"Workspace"}]}"#.utf8)
            case "/v1/projects/workspace/documents": data = Data(#"{"documents":[]}"#.utf8)
            case "/v1/projects/workspace/presence":
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                if body["leave"] as? Bool == true { fixture.presenceLeaves += 1 }
                else { fixture.presenceJoins += 1 }
                data = Data(#"{"version":1,"workspaceId":"workspace","ttlSeconds":30,"members":[],"leases":[]}"#.utf8)
            case "/v1/auth/me": data = Data(#"{"reviewUsernames":true,"creatorOnlyMarkups":true,"reviewUsername":"Reviewer"}"#.utf8)
            case let path where path.hasSuffix("/sessions"): data = Data(#"{"session":{"id":"session"}}"#.utf8)
            case "/v1/documents/checkpoint/ops" where request.httpMethod == "POST":
                let append = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                fixture.ids.append(append["clientOpId"] as! String)
                fixture.diskCounts.append(try fixture.outbox.load().count)
                try fixture.onAppend?(fixture.ids.count)
                if fixture.failAt == fixture.ids.count { throw URLError(.notConnectedToInternet) }
                return try await session.data(for: request)
            case let path where path.hasSuffix("/ops"):
                if fixture.opsStatus == 403 {
                    return (Data(#"{"error":"Access ended"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
                }
                data = Data(#"{"ops":[]}"#.utf8)
            default: data = fixture.bytes
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let editor = MainViewController()
        let review = SharedReviewWindowController(outboxDirectory: fixture.directory.appendingPathComponent("outbox"), cacheDirectory: fixture.cache)
        review.makeReviewAPI = { _, _ in api }
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
