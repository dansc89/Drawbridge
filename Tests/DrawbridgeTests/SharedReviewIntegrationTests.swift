import AppKit
import PDFKit
import XCTest
@testable import Drawbridge

final class SharedReviewIntegrationTests: XCTestCase {
    @MainActor
    func testTwoEditorsAndAReopenedReviewReplayRevisions() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["DRAWBRIDGE_TEST_SYNC_ORIGIN"],
              let origin = URL(string: base),
              let passwordFile = environment["DRAWBRIDGE_TEST_SYNC_PASSWORD_FILE"] else {
            throw XCTSkip("Requires an isolated sync backend and a pilot test password.")
        }
        _ = NSApplication.shared
        let password = try String(contentsOfFile: passwordFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        func client(_ author: String, device: String) async throws -> SharedReviewAPI {
            let login = try await SettingsWindowController.authenticate(
                origin: origin, username: "test-office", password: password, markupAuthor: author, deviceKey: device)
            XCTAssertEqual(login.displayName, author)
            return SharedReviewAPI(origin: origin, token: login.token, displayName: login.displayName, instanceID: login.instanceId)
        }
        let firstDevice = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + String(repeating: "a", count: 32)
        let first = try await client("Test reviewer one", device: firstDevice)
        let second = try await client("Test reviewer one", device: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + String(repeating: "b", count: 32))
        XCTAssertNotEqual(first.instanceID, second.instanceID)
        let projects: SharedReviewAPI.ProjectList = try await first.get("projects")
        let project = try XCTUnwrap(projects.projects.first)
        let username = "Reviewer-" + UUID().uuidString.prefix(8)
        do {
            let _: SharedReviewAPI.CreatedDocument = try await second.post(
                "projects/\(project.id)/documents", ["name": "Unclaimed upload"])
            XCTFail("An unclaimed reviewer could create a shared document")
        } catch let error as SharedReviewError {
            XCTAssertEqual(error.statusCode, 403)
        }
        let claimed = try await first.claimUsername(username)
        XCTAssertEqual(claimed.username, username)
        do {
            _ = try await second.claimUsername(username.lowercased())
            XCTFail("The server accepted a case-insensitive duplicate username")
        } catch let error as SharedReviewError {
            XCTAssertEqual(error.statusCode, 409)
        }
        _ = try await second.claimUsername(username + "-2")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Drawbridge-pilot-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let image = NSImage(size: NSSize(width: 420, height: 320), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let pdf = PDFDocument()
        pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(pdf.write(to: file))
        let folderPath = "projects/\(project.id)/folders"
        let root: SharedReviewAPI.CreatedFolder = try await first.post(folderPath,
            SharedReviewAPI.FolderRequest(name: "QA \(UUID())", parentId: nil))
        let child: SharedReviewAPI.CreatedFolder = try await first.post(folderPath,
            SharedReviewAPI.FolderRequest(name: "Mechanical", parentId: root.folder.id))
        XCTAssertEqual(child.folder.parent_id, root.folder.id)
        do {
            let _: SharedReviewAPI.CreatedFolder = try await second.post(folderPath,
                SharedReviewAPI.FolderRequest(name: "mechanical", parentId: root.folder.id))
            XCTFail("Duplicate sibling folder was accepted")
        } catch let error as SharedReviewError {
            XCTAssertEqual(error.statusCode, 409)
        }
        let document = try await first.upload(file, project: project, folderID: child.folder.id)
        let listing: SharedReviewAPI.DocumentList = try await second.get("projects/\(project.id)/documents")
        XCTAssertEqual(listing.documents.first { $0.id == document.id }?.folder_id, child.folder.id)
        XCTAssertTrue(listing.folders?.contains { $0.id == child.folder.id } == true)
        let outboxDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outboxDirectory) }
        let cacheDirectory = outboxDirectory.appendingPathComponent("cache")
        let editorA = MainViewController()
        let editorB = MainViewController()
        let a = SharedReviewWindowController(outboxDirectory: outboxDirectory, cacheDirectory: cacheDirectory)
        let b = SharedReviewWindowController(outboxDirectory: outboxDirectory, cacheDirectory: cacheDirectory)
        a.editor = editorA
        b.editor = editorB
        editorA.sharedReview = a
        editorB.sharedReview = b
        try await a.open(document, using: first)
        try await b.open(document, using: second)
        defer {
            if let url = a.tabURL { editorA.unregisterSessionDocument(url) }
            if let url = b.tabURL { editorB.unregisterSessionDocument(url) }
        }
        let cache = try XCTUnwrap(SharedReviewPDFCache(origin: origin, instanceID: first.instanceID,
                                                        document: document, directory: cacheDirectory))
        XCTAssertEqual(try cache.load(), try Data(contentsOf: file))
        XCTAssertTrue(editorA.isActiveReview)
        XCTAssertTrue(editorB.isActiveReview)
        let reviewPane = try XCTUnwrap(editorB.pdfView.superview as? PDFPaneContainerView)
        XCTAssertFalse(reviewPane.header.isHidden)
        XCTAssertTrue(reviewPane.titleLabel.stringValue.hasPrefix("Drawbridge Review · "))
        XCTAssertTrue(reviewPane.closeButton.isHidden)
        XCTAssertEqual(editorA.openDocumentURL, a.tabURL)
        XCTAssertTrue(a.window?.isVisible == false)
        XCTAssertFalse(editorA.canManagePages)
        let pageA = try XCTUnwrap(editorA.pdfView.document?.page(at: 0))
        let pageB = try XCTUnwrap(editorB.pdfView.document?.page(at: 0))
        try await eventually { editorA.pdfView.rectangleMarkup.canEdit() && editorB.pdfView.rectangleMarkup.canEdit() }
        let annotation = try XCTUnwrap(editorA.pdfView.rectangleMarkup.create(
            on: pageA, bounds: CGRect(x: 40, y: 40, width: 70, height: 60)))
        let id = try XCTUnwrap(RectangleMarkupRecord.identity(annotation))
        try await eventually { b.revision == 1 && pageB.annotations.contains { RectangleMarkupRecord.identity($0) == id } }
        let received = try XCTUnwrap(pageB.annotations.first { RectangleMarkupRecord.identity($0) == id })
        XCTAssertEqual(received.userName, username)
        let moved = CGRect(x: 120, y: 80, width: 70, height: 60)
        XCTAssertTrue(received.isReadOnly)
        let originalBounds = received.bounds
        editorB.pdfView.rectangleMarkup.setBounds(moved, of: received, on: pageB, action: "Move")
        XCTAssertEqual(received.bounds, originalBounds)
        let joined: SharedReviewAPI.CreatedSession = try await second.post("documents/\(document.id)/sessions", ["name": "Attempted edit"])
        var forged = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: annotation, pageIndex: 0))
        forged.text = "Unauthorized edit"
        for record in [forged, nil] {
            do {
                let _: SharedReviewAPI.Receipt = try await second.post("documents/\(document.id)/ops",
                    SharedReviewAPI.Append(sessionId: joined.session.id, clientOpId: UUID().uuidString,
                        payload: .init(id: id, page: 0, record: record, ownerInstanceId: first.instanceID)))
                XCTFail("The server accepted a revision from a different creator")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("403"))
            }
        }
        editorB.openDocument(at: file)
        XCTAssertFalse(editorB.isActiveReview)
        XCTAssertTrue(reviewPane.header.isHidden)
        editorA.pdfView.rectangleMarkup.setBounds(moved, of: annotation, on: pageA, action: "Move")
        try await eventually {
            a.revision == 2 && pageA.annotations.contains { RectangleMarkupRecord.identity($0) == id && $0.bounds == moved }
        }
        try await eventually { b.revision == 2 }
        editorB.openDocument(at: try XCTUnwrap(b.tabURL))
        XCTAssertTrue(editorB.pdfView.document?.page(at: 0) === pageB)
        XCTAssertEqual(pageB.annotations.first?.bounds, moved)
        let editorReopened = MainViewController()
        let reopened = SharedReviewWindowController(outboxDirectory: outboxDirectory, cacheDirectory: cacheDirectory)
        reopened.editor = editorReopened
        editorReopened.sharedReview = reopened
        let signedInAgain = try await client("Renamed reviewer", device: firstDevice)
        XCTAssertEqual(signedInAgain.instanceID, first.instanceID)
        try await reopened.open(document, using: signedInAgain)
        defer { if let url = reopened.tabURL { editorReopened.unregisterSessionDocument(url) } }
        try await eventually {
            reopened.revision == 2 && editorReopened.pdfView.document?.page(at: 0)?.annotations.first?.bounds == moved
        }
        let restored = try XCTUnwrap(editorReopened.pdfView.document?.page(at: 0)?.annotations.first)
        XCTAssertFalse(restored.isReadOnly)
        XCTAssertEqual(restored.userName, username)
        editorReopened.pdfView.rectangleMarkup.selectFromList(restored)
        editorReopened.pdfView.rectangleMarkup.deleteSelected()
        try await eventually {
            a.revision == 3 && reopened.revision == 3 && pageA.annotations.isEmpty
                && editorReopened.pdfView.document?.page(at: 0)?.annotations.isEmpty == true
        }
        let markup = editorA.pdfView.rectangleMarkup
        let bounds = CGRect(x: 10, y: 10, width: 100, height: 100)
        let points = [CGPoint(x: 20, y: 20), CGPoint(x: 70, y: 30), CGPoint(x: 50, y: 80)]
        let scale = DrawingScale(unitsPerPoint: 0.1, unit: "ft", name: "Test scale")
        let area = DrawingMeasurement(kind: .area, scale: scale, closed: true)
        let length = DrawingMeasurement(kind: .perimeter, scale: scale, closed: false)
        let ellipse = try XCTUnwrap(markup.create(on: pageA, bounds: bounds, kind: .ellipse))
        let line = try XCTUnwrap(markup.create(on: pageA, bounds: bounds, kind: .line, endpoints: (points[0], points[1])))
        let arrow = try XCTUnwrap(markup.create(on: pageA, bounds: bounds, kind: .arrow, endpoints: (points[0], points[1])))
        let text = try XCTUnwrap(markup.create(on: pageA, bounds: bounds, kind: .text, text: "Review text"))
        let polygon = try XCTUnwrap(markup.create(on: pageA, bounds: bounds, kind: .polygon, vertices: points))
        markup.tool = .cloud
        let cloud = try XCTUnwrap(markup.createPolyline(on: pageA, points: points, closed: true))
        let areaAnnotation = try XCTUnwrap(markup.create(on: pageA, bounds: bounds, kind: .polygon, vertices: points, measurement: area))
        let distance = try XCTUnwrap(markup.create(on: pageA, bounds: bounds, kind: .polyline, vertices: Array(points.prefix(2)), measurement: length))
        markup.tool = .pen
        let pen = try XCTUnwrap(markup.create(on: pageA, bounds: bounds, kind: .polyline, vertices: points))
        markup.tool = .highlight
        let highlight = try XCTUnwrap(markup.create(on: pageA, bounds: bounds, kind: .polyline, vertices: points))
        let snapshot = try XCTUnwrap(markup.pasteSnapshot(SnapshotPayload(data: try Data(contentsOf: file)),
            on: pageA, center: CGPoint(x: 210, y: 160)))
        let added = [ellipse, line, arrow, text, polygon, cloud, areaAnnotation, distance, pen, highlight, snapshot]
        let ids = Set(added.compactMap(RectangleMarkupRecord.identity))
        XCTAssertEqual(ids.count, added.count)
        try await eventually { b.revision == 3 + added.count }
        let remote = pageB.annotations.filter { annotation in
            RectangleMarkupRecord.identity(annotation).map(ids.contains) == true
        }
        XCTAssertEqual(remote.count, added.count)
        XCTAssertEqual(remote.filter(RectangleMarkupRecord.isCloud).count, 1)
        XCTAssertTrue(remote.allSatisfy { $0.isReadOnly && $0.userName == username })
        XCTAssertEqual(remote.first { $0.type == "FreeText" }?.contents, "Review text")
        XCTAssertEqual(remote.compactMap(MeasurementMetadata.measurement).count, 2)

        // Simulate a restart with a lost receipt followed by an edit that never reached the server.
        try await eventually { a.revision == 3 + added.count && reopened.revision == a.revision }
        editorA.unregisterSessionDocument(try XCTUnwrap(a.tabURL))
        editorReopened.unregisterSessionDocument(try XCTUnwrap(reopened.tabURL))
        let outbox = try SharedReviewOutbox(origin: origin, instanceID: first.instanceID,
                                            documentID: document.id, basePDF: Data(contentsOf: file),
                                            directory: outboxDirectory)
        var queuedRecord = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: text, pageIndex: 0))
        queuedRecord.text = "Already committed"
        let retry = SharedReviewOutbox.Edit(clientOpId: UUID().uuidString,
                                           payload: .init(id: queuedRecord.id, page: 0, record: queuedRecord))
        queuedRecord.text = "Recovered after restart"
        let unsent = SharedReviewOutbox.Edit(clientOpId: UUID().uuidString,
                                            payload: .init(id: queuedRecord.id, page: 0, record: queuedRecord))
        try outbox.save([retry, unsent])
        let retrySession: SharedReviewAPI.CreatedSession = try await first.post(
            "documents/\(document.id)/sessions", ["name": "Lost receipt"])
        let receipt: SharedReviewAPI.Receipt = try await first.post("documents/\(document.id)/ops",
            SharedReviewAPI.Append(sessionId: retrySession.session.id, clientOpId: retry.clientOpId, payload: retry.payload))
        XCTAssertEqual(receipt.op.seq, 4 + added.count)
        try await reopened.open(document, using: signedInAgain)
        try await eventually { reopened.revision == 5 + added.count && b.revision == reopened.revision }
        XCTAssertEqual(try outbox.load(), [])
        XCTAssertTrue(pageB.annotations.contains {
            RectangleMarkupRecord.identity($0) == queuedRecord.id && $0.contents == "Recovered after restart"
        })

        let exportedURL = outboxDirectory.appendingPathComponent("Local export.pdf")
        let basePDF = try XCTUnwrap(b.basePDF)
        let visibleRecords = RectangleMarkupRecord.capture(try XCTUnwrap(b.reviewPDF))
        try await Task.detached {
            try SharedReviewPDFExport.write(basePDF: basePDF, records: visibleRecords, to: exportedURL)
        }.value
        let exported = try XCTUnwrap(PDFDocument(url: exportedURL))
        XCTAssertEqual(exported.pageCount, 1)
        let exportedRecords = RectangleMarkupRecord.capture(exported)
        XCTAssertEqual(Set(exportedRecords.map(\.id)), Set(visibleRecords.map(\.id)))
        XCTAssertTrue(exportedRecords.contains { $0.id == queuedRecord.id && $0.text == "Recovered after restart" })
        XCTAssertEqual(exportedRecords.compactMap(\.measurement).count, 2)
        XCTAssertEqual(exportedRecords.first { $0.revisionCloud == true }?.vertices, points)

        let movePath = "projects/\(project.id)/move-documents"
        let removePath = "projects/\(project.id)/remove-item"
        let _: SharedReviewAPI.OrganizationReceipt = try await first.post(movePath,
            SharedReviewAPI.MoveRequest(ids: [document.id], folderId: root.folder.id))
        let movedList: SharedReviewAPI.DocumentList = try await second.get("projects/\(project.id)/documents")
        XCTAssertEqual(movedList.documents.first { $0.id == document.id }?.folder_id, root.folder.id)
        let history: SharedReviewAPI.Operations = try await second.get("documents/\(document.id)/ops")
        XCTAssertEqual(history.ops.count, 5 + added.count)
        for (request, status) in [
            (SharedReviewAPI.RemoveRequest(kind: "document", id: document.id, confirmation: "wrong"), 400),
            (SharedReviewAPI.RemoveRequest(kind: "folder", id: root.folder.id, confirmation: username), 409)
        ] {
            do {
                let _: SharedReviewAPI.OrganizationReceipt = try await first.post(removePath, request)
                XCTFail("Unsafe deletion was accepted")
            } catch let error as SharedReviewError {
                XCTAssertEqual(error.statusCode, status)
            }
        }
        for (kind, id) in [("document", document.id), ("folder", child.folder.id), ("folder", root.folder.id)] {
            let result: SharedReviewAPI.OrganizationReceipt = try await first.post(removePath,
                SharedReviewAPI.RemoveRequest(kind: kind, id: id, confirmation: username))
            XCTAssertTrue(result.ok)
        }
        let remaining: SharedReviewAPI.DocumentList = try await second.get("projects/\(project.id)/documents")
        XCTAssertFalse(remaining.documents.contains { $0.id == document.id })
        XCTAssertFalse(remaining.folders?.contains { $0.id == root.folder.id || $0.id == child.folder.id } ?? true)
        do {
            _ = try await second.download(document)
            XCTFail("Removed PDF was still downloadable")
        } catch let error as SharedReviewError {
            XCTAssertEqual(error.statusCode, 403)
        }

    }

    @MainActor
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SharedReviewError("Timed out waiting for a revision.") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
