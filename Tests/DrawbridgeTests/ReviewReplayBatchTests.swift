import AppKit
import PDFKit
import CryptoKit
import XCTest
@testable import Drawbridge

@MainActor final class ReviewReplayBatchTests: XCTestCase {
    func testDensePageReplayBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["DRAWBRIDGE_REPLAY_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in dense-page replay timing")
        }
        try await withReview { review, _ in
            let page = try XCTUnwrap(review.reviewPDF?.page(at: 0))
            for index in 0..<6000 {
                let annotation = PDFAnnotation(bounds: CGRect(x: index % 200, y: index % 150, width: 8, height: 6), forType: .square, withProperties: nil)
                annotation.contents = "Existing PDF markup"
                page.addAnnotation(annotation)
            }
            let ids = (0..<250).map { RectangleMarkupRecord.prefix + "dense-\($0)" }
            try review.replayOperations(try ids.enumerated().map { try self.operation($0.offset + 1, $0.element) }, instanceID: "device")
            var samples: [Double] = []
            var scans: [Int] = []
            review.replayAnnotationScanObserver = { _, count in scans.append(count) }
            for round in 0..<3 {
                scans.removeAll()
                let ops = try ids.enumerated().map { try self.operation((round+1)*250+$0.offset+1, $0.element, text: round % 2 == 0 ? "updated" : "last") }
                let begin = CFAbsoluteTimeGetCurrent()
                try review.replayOperations(ops, instanceID: "device")
                samples.append((CFAbsoluteTimeGetCurrent()-begin)*1000)
                XCTAssertEqual(scans, [6250], "One page scan per batch, rather than one per revision")
            }
            XCTAssertEqual(page.annotations.count, 6250)
            XCTAssertEqual(review.revision, 1000)
            print("DENSE_REPLAY existing=6000 operations=250 samplesMs=\(samples)")
        }
    }
    func testReplayIndexPreservesDuplicateIdentityOrderAndRebuildsAfterLocalMutation() async throws {
        try await withReview { review, _ in
            let page = try XCTUnwrap(review.reviewPDF?.page(at: 0))
            let id = RectangleMarkupRecord.prefix + "duplicate"
            for _ in 0..<2 {
                let annotation = PDFAnnotation(bounds: CGRect(x: 10,y: 10,width: 20,height: 20),forType: .square,withProperties: nil)
                annotation.setValue(id,forAnnotationKey: RectangleMarkupRecord.identityKey)
                page.addAnnotation(annotation)
            }
            var scans = 0
            review.replayAnnotationScanObserver = { _, _ in scans += 1 }
            try review.replayOperations([self.operation(1,id,text:"updated"), self.operation(2,id,text:nil)],instanceID:"device")
            XCTAssertEqual(scans,1)
            XCTAssertEqual(page.annotations.count,1)
            let first = try XCTUnwrap(page.annotations.first)
            XCTAssertEqual(first.bounds.minX,40,"Removal must preserve the first-match semantics of duplicate IDs")
            page.removeAnnotation(first)
            try review.replayOperations([self.operation(3,id,text:"fresh")],instanceID:"device")
            XCTAssertEqual(scans,2,"A later batch must observe local changes, rather than a retained stale index")
            XCTAssertEqual(page.annotations.count,1)
            XCTAssertEqual(page.annotations.first?.bounds.minX,20)
        }
    }
    func testLargeSnapshotPasteIsDurablyQueuedWithoutRecoveryOnlyCloseBlock() async throws {
        try await withReview { review, editor in
            let page = try XCTUnwrap(review.reviewPDF?.page(at: 0))
            let source=PDFDocument();let sourcePage=PDFPage();sourcePage.setBounds(CGRect(x:0,y:0,width:100,height:80),for:.mediaBox);source.insert(sourcePage,at:0)
            var bytes=try XCTUnwrap(source.dataRepresentation())
            bytes.append(Data(("\n%"+String(repeating:"x",count:2*1024*1024)+"\n").utf8))
            editor.pdfView.rectangleMarkup.bind(to:review.reviewPDF)
            editor.pdfView.rectangleMarkup.canEdit = { true }
            let annotation=try XCTUnwrap(editor.pdfView.rectangleMarkup.pasteSnapshot(SnapshotPayload(data:bytes),on:page,center:CGPoint(x:100,y:100)))
            review.recordChanges(on:page)
            XCTAssertNotNil(annotation.page)
            XCTAssertFalse(review.hasPendingChanges,"Complete Snapshot must be saved in the durable outbox, not trapped in invalidPages")
            XCTAssertTrue(review.syncStatus.contains("pending"))
            XCTAssertFalse(review.syncStatus.contains("can’t sync"))
        }
    }
    func testSnapshotReplayReplacementAndDeletionRetireCachedAppearance() async throws {
        try await withReview { review, editor in
            let page = try XCTUnwrap(review.reviewPDF?.page(at: 0))
            let source = PDFDocument(); let sourcePage = PDFPage()
            sourcePage.setBounds(CGRect(x: 0, y: 0, width: 100, height: 80), for: .mediaBox)
            source.insert(sourcePage, at: 0)
            let session = RectangleMarkupController(); session.bind(to: review.reviewPDF); session.canEdit = { true }
            let initial = try XCTUnwrap(session.pasteSnapshot(SnapshotPayload(data: XCTUnwrap(source.dataRepresentation())), on: page, center: CGPoint(x: 100, y: 100)) as? DrawbridgeSnapshotAnnotation)
            let record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: initial, pageIndex: 0))
            var reasons: [MarkupPDFView.AnnotationRefreshReason] = []
            editor.pdfView.annotationRefreshObserver = { _, _, _, reason in reasons.append(reason) }
            let update = SharedReviewAPI.Markup(id: record.id, page: 0, record: record, ownerInstanceId: "remote")
            try review.replayOperations([.init(seq: 1, op_type: "drawbridge.markup.v1", payload: update)], instanceID: "device")
            XCTAssertTrue(initial.isRetired); XCTAssertFalse(initial.shouldDisplay)
            let replacement = try XCTUnwrap(page.annotations.compactMap { $0 as? DrawbridgeSnapshotAnnotation }.first)
            XCTAssertFalse(replacement.isRetired)
            let deletion = SharedReviewAPI.Markup(id: record.id, page: 0, record: nil, ownerInstanceId: "remote")
            try review.replayOperations([.init(seq: 2, op_type: "drawbridge.markup.v1", payload: deletion)], instanceID: "device")
            XCTAssertTrue(replacement.isRetired); XCTAssertFalse(replacement.shouldDisplay)
            XCTAssertFalse(page.annotations.contains { $0 is DrawbridgeSnapshotAnnotation || $0 is SnapshotViewportTileAnnotation })
            XCTAssertEqual(reasons.count, 2)
            XCTAssertTrue(reasons.allSatisfy { $0 == .snapshotPresenceChanged })
        }
    }

    func testNativeLayerVisibilityPreservesReviewPagesUndoAndRemoteMembership() async throws {
        try await withReview(basePDF: ReviewPDFLayerFixture.data()) { review, editor in
            let document = try XCTUnwrap(review.reviewPDF), page = try XCTUnwrap(document.page(at: 0))
            let session = editor.pdfView.rectangleMarkup
            session.bind(to: document); session.canEdit = { true }; session.canManageLayers = { false }
            session.undo.groupsByEvent = false
            session.undo.beginUndoGrouping()
            let snapshot = try XCTUnwrap(session.pasteSnapshot(SnapshotPayload(data: ReviewPDFLayerFixture.data()), on: page, center: CGPoint(x: 50, y: 50)))
            session.undo.endUndoGrouping()
            session.assignPDFLayer(0, to: [snapshot])
            let record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: snapshot, pageIndex: 0))
            let layer = try XCTUnwrap(EmbeddedPDFLayers.read(document).first)
            try await review.setPDFLayerVisible(layer, visible: false)
            XCTAssertTrue(review.reviewPDF === document); XCTAssertTrue(document.page(at: 0) === page)
            XCTAssertFalse(snapshot.shouldDisplay)
            session.undo.undo(); XCTAssertNil(MarkupLayers.pdfIndex(snapshot)); XCTAssertTrue(snapshot.shouldDisplay)
            session.undo.redo(); XCTAssertEqual(MarkupLayers.pdfIndex(snapshot), 0); XCTAssertFalse(snapshot.shouldDisplay)
            let remoteAnnotation = try record.clipboardAnnotation(contents: record.text, rotation: 0)
            let remote = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: remoteAnnotation, pageIndex: 0))
            let payload = SharedReviewAPI.Markup(id: remote.id, page: 0, record: remote, ownerInstanceId: "remote")
            try review.replayOperations([.init(seq: 10, op_type: "drawbridge.markup.v1", payload: payload)], instanceID: "device")
            let received = try XCTUnwrap(page.annotations.first { RectangleMarkupRecord.identity($0) == remote.id })
            XCTAssertEqual(MarkupLayers.pdfIndex(received), 0); XCTAssertFalse(received.shouldDisplay)
            try await review.setPDFLayerVisible(layer, visible: true)
            XCTAssertTrue(snapshot.shouldDisplay); XCTAssertTrue(received.shouldDisplay)
        }
    }

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

    func testOwnReviewCalibrationSyncsRestoresAndNeverChangesAnotherReviewersScale() async throws {
        try await withReview { review, editor in
            let page = try XCTUnwrap(review.reviewPDF?.page(at:0))
            let scale = try XCTUnwrap(DrawingScale.architectural(inches:0.125,feet:1,name:"Test Scale"))
            let controller = editor.pdfView.rectangleMarkup
            controller.bind(to:review.reviewPDF)
            controller.canEdit = { true }
            controller.reviewScaleIdentity = { review.scaleMarkerIdentity(on:$0) }
            controller.applyDrawingScale(scale,to:[page])
            review.recordChanges(on:page)
            let marker = try XCTUnwrap(page.annotations.first(where:MeasurementMetadata.isPageScaleMetadata))
            let record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation:marker,pageIndex:0))
            XCTAssertEqual(record.id,review.scaleMarkerIdentity(on:page))
            XCTAssertEqual(record.pageScale,scale)
            // Replay in an independently empty page state using the real decoder.
            let target = try XCTUnwrap(review.reviewPDF?.page(at:1))
            var remote = RectangleMarkupRecord(id:try XCTUnwrap(review.scaleMarkerIdentity(on:target)),pageIndex:1,bounds:record.bounds,red:record.red,green:record.green,blue:record.blue,lineWidth:record.lineWidth)
            remote.pageScale = scale
            func op(_ owner: String, _ seq: Int) throws -> SharedReviewAPI.Operation {
                let payload = SharedReviewAPI.Markup(id:remote.id,page:1,record:remote,ownerInstanceId:owner)
                let encoded = try JSONSerialization.jsonObject(with:JSONEncoder().encode(payload))
                return try JSONDecoder().decode(SharedReviewAPI.Operation.self,from:JSONSerialization.data(withJSONObject:["seq":seq,"op_type":"drawbridge.markup.v1","payload":encoded]))
            }
            try review.replayOperations([op("other",100)],instanceID:"device")
            XCTAssertNil(MeasurementMetadata.scale(on:target))
            try review.replayOperations([op("device",101)],instanceID:"device")
            XCTAssertEqual(MeasurementMetadata.scale(on:target),scale)
            let restored = try XCTUnwrap(target.annotations.first(where:MeasurementMetadata.isPageScaleMetadata))
            XCTAssertFalse(restored.shouldDisplay)
            XCTAssertFalse(restored.shouldPrint)
            XCTAssertTrue(restored.isReadOnly)
        }
    }

    func testNotificationsPanelAppearsOnlyForActiveReviewDocument() async throws {
        try await withReview { review, editor in
            _ = editor.view
            editor.updateReviewNotificationsPanel()
            XCTAssertFalse(editor.reviewNotificationsPanel.isHidden)
            let reviewDocument = try XCTUnwrap(review.reviewPDF)
            let local = PDFDocument(); local.insert(PDFPage(), at: 0)
            editor.pdfView.setMarkupDocument(local)
            editor.updateReviewNotificationsPanel()
            XCTAssertTrue(editor.reviewNotificationsPanel.isHidden)
            editor.pdfView.setMarkupDocument(reviewDocument)
            editor.updateReviewNotificationsPanel()
            XCTAssertFalse(editor.reviewNotificationsPanel.isHidden)
        }
    }

    func testOriginalDrawingAssignmentInReviewKeepsCanonicalPageAndSmallWireRecord() async throws {
        try await withReview(basePDF: ReviewPDFLayerFixture.forms()) { review, editor in
            let document = try XCTUnwrap(review.reviewPDF), page = try XCTUnwrap(document.page(at:0))
            let session = editor.pdfView.rectangleMarkup
            session.bind(to:document); session.canEdit = { true }; session.undo.groupsByEvent = false
            let selection = try XCTUnwrap(PDFPathScanner.index(page: XCTUnwrap(page.pageRef)).nativeSelection(at:CGPoint(x:10,y:15),tolerance:2))
            try await editor.originalDrawingLayers.assign(page:page,selection:selection,layer:1)
            XCTAssertTrue(editor.pdfView.document === document); XCTAssertTrue(document.page(at:0) === page)
            let carrier = try XCTUnwrap(page.annotations.first { NativeDrawingAssignment.read($0) != nil })
            XCTAssertFalse(carrier.shouldDisplay); XCTAssertNil(session.selected)
            let record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation:carrier,pageIndex:0))
            XCTAssertLessThan(try JSONEncoder().encode(record).count,4096,"Only the vector selector and membership sync, never the drawing bytes")
            XCTAssertEqual(record.pdfLayerIndex,1)
            let layer = try XCTUnwrap(EmbeddedPDFLayers.read(document).first)
            try await review.setPDFLayerVisible(layer,visible:false)
            XCTAssertTrue(editor.pdfView.document === document)
            session.undo.undo()
            XCTAssertFalse(page.annotations.contains { NativeDrawingAssignment.read($0) != nil })
            session.undo.redo()
            XCTAssertEqual(page.annotations.compactMap { NativeDrawingAssignment.read($0) }.count,1)
        }
    }

    func testAlertCanTargetAnotherAuthorsReadOnlyMarkupAndJumpToItsPage() async throws {
        let id = RectangleMarkupRecord.prefix + "foreign-alert"
        var sent = 0
        let alert: [String: Any] = ["id":1,"document":["id":"replay","name":"Replay.pdf","file_size":100],
            "markupId":id,"page":1,"bounds":[20,20,60,30],"sender":"Other","kind":"text","createdAt":1800000000000,"readAt":NSNull()]
        let encodedAlert = try JSONSerialization.data(withJSONObject:alert)
        try await withReview(response: { request in
            switch request.url!.path {
            case "/v1/documents/replay/alert-recipients": return Data(#"{"users":[{"id":"recipient","name":"Recipient","email":"recipient@example.com"}]}"#.utf8)
            case "/v1/documents/replay/alerts":
                sent += 1
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String:Any])
                XCTAssertEqual(body["markupId"] as? String,id); XCTAssertEqual(body["recipientId"] as? String,"recipient")
                return try JSONSerialization.data(withJSONObject:["alert":JSONSerialization.jsonObject(with:encodedAlert),"duplicate":false])
            case "/v1/notifications": return Data(#"{"userId":"tester","alerts":[],"cursor":0,"oldest":null,"hasMore":false}"#.utf8)
            default:return nil
            }
        }) { review, editor in
            try review.replayOperations([self.operation(1,id,page:1,text:"Foreign",owner:"other-device")],instanceID:"device")
            let page = try XCTUnwrap(review.reviewPDF?.page(at:1))
            let annotation = try XCTUnwrap(page.annotations.first)
            XCTAssertTrue(annotation.isReadOnly); XCTAssertEqual(review.alertTarget(annotation),id)
            let roster = try await review.alertRecipients(); XCTAssertEqual(roster.first?.label,"recipient@example.com")
            try await review.sendAlert(markup:id,recipient:"recipient"); XCTAssertEqual(sent,1)
            let notification = try JSONDecoder().decode(SharedReviewAPI.ReviewNotification.self,from:encodedAlert)
            try await review.openNotification(notification)
            XCTAssertTrue(editor.pdfView.currentPage === page)
            XCTAssertTrue(annotation.isReadOnly,"Alerting never changes editing permissions")
        }
    }

    func testOriginalForeignPDFAnnotationFollowsNativeLayerVisibilityInReview() async throws {
        try await withReview(basePDF:ReviewPDFLayerFixture.data(withAnnotation:true)) { review, editor in
            let document = try XCTUnwrap(review.reviewPDF), page = try XCTUnwrap(document.page(at:0))
            let annotation = try XCTUnwrap(page.annotations.first)
            let session = editor.pdfView.rectangleMarkup; session.bind(to:document)
            let layer = try XCTUnwrap(EmbeddedPDFLayers.read(document).first)
            XCTAssertTrue(annotation.shouldDisplay); XCTAssertTrue(annotation.isReadOnly)
            try await review.setPDFLayerVisible(layer,visible:false)
            XCTAssertFalse(annotation.shouldDisplay)
            try await review.setPDFLayerVisible(layer,visible:true)
            XCTAssertTrue(annotation.shouldDisplay); XCTAssertTrue(annotation.isReadOnly)
            XCTAssertTrue(page.annotations.first === annotation)
        }
    }

    func testRemoteOriginalDrawingAssignmentCanBeHiddenWithoutChangingOwnership() async throws {
        try await withReview(basePDF:ReviewPDFLayerFixture.forms()) { review, editor in
            let document = try XCTUnwrap(review.reviewPDF), page = try XCTUnwrap(document.page(at:0))
            var record = RectangleMarkupRecord(id:RectangleMarkupRecord.prefix + "remote-drawing",pageIndex:0,bounds:CGRect(x:9,y:9,width:12,height:12),red:0,green:0,blue:0,lineWidth:1)
            record.nativeDrawing = .init(path:[0,0],originalLayers:[0]); record.pdfLayerIndex = 1; record.strokeOpacity = 0
            let payload = SharedReviewAPI.Markup(id:record.id,page:0,record:record,ownerInstanceId:"other-device")
            try review.replayOperations([.init(seq:1,op_type:"drawbridge.markup.v1",payload:payload)],instanceID:"device")
            let annotation = try XCTUnwrap(page.annotations.first)
            XCTAssertTrue(annotation.isReadOnly); XCTAssertFalse(annotation.shouldDisplay)
            let layer = try XCTUnwrap(EmbeddedPDFLayers.read(document).first)
            try await review.setPDFLayerVisible(layer,visible:false)
            XCTAssertTrue(editor.pdfView.document === document)
            XCTAssertTrue(annotation.isReadOnly); XCTAssertFalse(annotation.shouldDisplay)
        }
    }

    func testAlertTargetsSnapshotAlreadyEmbeddedInUploadedPDFByItsOriginalSlot() async throws {
        let bytes = ReviewPDFLayerFixture.data(), document = try XCTUnwrap(PDFDocument(data:bytes)), page = try XCTUnwrap(document.page(at:0))
        let view = MarkupPDFView(); view.setMarkupDocument(document); view.rectangleMarkup.bind(to:document); view.rectangleMarkup.canEdit = { true }
        let snapshot = try XCTUnwrap(view.rectangleMarkup.pasteSnapshot(SnapshotPayload(data:bytes),on:page,center:CGPoint(x:50,y:50)))
        view.rectangleMarkup.assignPDFLayer(1,to:[snapshot])
        let record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation:snapshot,pageIndex:0))
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pdf")
        defer { try? FileManager.default.removeItem(at:saved) }
        try SharedReviewPDFExport.write(basePDF:bytes,records:[record],to:saved)
        try await withReview(basePDF:Data(contentsOf:saved)) { review, _ in
            let annotation = try XCTUnwrap(review.reviewPDF?.page(at:0)?.annotations.first(where:SnapshotPayload.isSnapshot))
            XCTAssertTrue(annotation.isReadOnly)
            XCTAssertTrue(try XCTUnwrap(review.alertTarget(annotation)).hasPrefix("base:0:"))
            XCTAssertEqual(MarkupLayers.pdfIndex(annotation),1)
        }
    }

    private func withReview(basePDF suppliedBase: Data? = nil, response: (@MainActor @Sendable (URLRequest) throws -> Data?)? = nil, _ body: (SharedReviewWindowController, MainViewController) async throws -> Void) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = PDFDocument()
        for index in 0..<2 {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 200), for: .mediaBox)
            pdf.insert(page, at: index)
        }
        let bytes = try suppliedBase ?? XCTUnwrap(pdf.dataRepresentation())
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let document = SharedReviewAPI.Document(id: "replay", name: "Replay.pdf", file_size: bytes.count, file_sha256: hash, folder_id: nil)
        let origin = URL(string: "https://offline.invalid")!
        let cache = try XCTUnwrap(SharedReviewPDFCache(origin: origin, instanceID: "device", document: document, directory: directory.appendingPathComponent("cache")))
        try cache.store(bytes)
        var api = SharedReviewAPI(origin: URL(string: "https://offline.invalid")!, token: "test", displayName: "Reviewer", instanceID: "device")
        api.transport = { request in
            if let data = try response?(request) { return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
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
        try await body(review, editor)
    }
}
