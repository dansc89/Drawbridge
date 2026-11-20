import AppKit
import PDFKit
import CryptoKit
import XCTest
@testable import Drawbridge

@MainActor final class ReviewSnapshotAssetSyncTests: XCTestCase {
    actor Wire {
        var assets: [String: Data] = [:]
        var uploads = 0
        var downloads = 0
        var uploadBytes = 0
        var corrupt = false
        func setCorrupt() { corrupt = true }
        func count() -> Int { uploads }
        func counters() -> (Int, Int) { (downloads, uploadBytes) }
        func request(_ request: URLRequest) throws -> (Data, URLResponse) {
            let path = request.url!.path
            let status: Int
            let body: Data
            switch request.httpMethod {
            case "HEAD": status = assets[path] == nil ? 404 : 200; body = Data()
            case "PUT":
                uploads += 1; uploadBytes += request.httpBody?.count ?? 0
                if request.value(forHTTPHeaderField: "X-Drawbridge-Snapshot-Compression") == "deflate-raw", let compressed = request.httpBody {
                    assets[path] = try (compressed as NSData).decompressed(using: .zlib) as Data
                } else { assets[path] = request.httpBody }
                status = 201; body = Data("{}".utf8)
            default: downloads += 1; status = assets[path] == nil ? 404 : 200; body = corrupt ? Data("corrupt".utf8) : assets[path] ?? Data()
            }
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: assets[path].map { ["Content-Length": String($0.count), "X-Drawbridge-Snapshot-SHA256": path.components(separatedBy:"/").last!] })!)
        }
    }
    private func markup() throws -> SharedReviewAPI.Markup {
        let page = PDFPage(); page.setBounds(CGRect(x: 0,y: 0,width: 300,height: 200),for: .mediaBox)
        let pdf = PDFDocument(); pdf.insert(page,at: 0)
        var bytes = try XCTUnwrap(pdf.dataRepresentation())
        bytes.append(Data(("\n%" + String(repeating: "x",count: 2 * 1024 * 1024) + "\n").utf8))
        let annotation = PDFAnnotation(bounds: CGRect(x: 10,y: 10,width: 100,height: 80),forType: .square,withProperties: nil)
        annotation.setValue(RectangleMarkupRecord.prefix + UUID().uuidString,forAnnotationKey: RectangleMarkupRecord.identityKey)
        var record = try XCTUnwrap(RectangleMarkupRecord.capture(annotation: annotation,pageIndex: 0))
        record.kind = .snapshot; record.snapshotData = bytes
        XCTAssertTrue(record.isValid)
        return .init(id: record.id,page: 0,record: record,ownerInstanceId: "sender")
    }
    func testLargeSnapshotOutboxWireSecondClientReplayAndRetry() async throws {
        let original = try markup(), wire = Wire()
        var sender = SharedReviewAPI(origin: URL(string:"https://offline.invalid")!,token:"test",displayName:"Sender",instanceID:"sender")
        sender.transport = { try await wire.request($0) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try SharedReviewOutbox(origin: sender.origin,instanceID:"sender",documentID:"document",basePDF:Data("base".utf8),directory:directory)
        let edit = SharedReviewOutbox.Edit(clientOpId:"stable-op",payload:original)
        try outbox.save([edit])
        let queued = try XCTUnwrap(outbox.load().first)
        let uploaded = try await sender.prepareSnapshot(queued.payload,document:"document",session:"session")
        XCTAssertNil(uploaded.record?.snapshotData)
        XCTAssertNotNil(uploaded.snapshotAsset)
        XCTAssertLessThan(try JSONEncoder().encode(uploaded).count, 1_500_000)
        _ = try await sender.prepareSnapshot(queued.payload,document:"document",session:"session")
        let uploadCount = await wire.count(); XCTAssertEqual(uploadCount,1)
        XCTAssertEqual(try outbox.load(),[edit],"Upload success alone must never acknowledge/consume the durable edit")
        var receiver = SharedReviewAPI(origin: sender.origin,token:"test",displayName:"Receiver",instanceID:"receiver")
        receiver.transport = { try await wire.request($0) }
        let result = try await receiver.resolveSnapshots([.init(seq:1,op_type:"drawbridge.markup.v1",payload:uploaded)],document:"document",session:"other-session")
        XCTAssertEqual(result.first?.payload,original)
        let restored = try XCTUnwrap(result.first?.payload?.record)
        let annotation = try restored.clipboardAnnotation(contents:restored.text,rotation:0)
        XCTAssertEqual(SnapshotPayload.read(annotation)?.data,original.record?.snapshotData)
        for seq in 2...12 {
            var styled = original.record!; styled.snapshotStyle.opacity = Double(seq)/20; styled.bounds.origin.x += Double(seq)
            let update = try await sender.prepareSnapshot(.init(id:styled.id,page:0,record:styled,ownerInstanceId:"sender"),document:"document",session:"session")
            XCTAssertEqual(update.snapshotAsset,uploaded.snapshotAsset)
            XCTAssertLessThan(try JSONEncoder().encode(update).count,4096,"Moves and style changes must only send small metadata")
            let replay = try await receiver.resolveSnapshots([.init(seq:seq,op_type:"drawbridge.markup.v1",payload:update)],document:"document",session:"other-session")
            XCTAssertEqual(replay.first?.payload?.record,styled)
        }
        let repeatedUploads = await wire.count(); XCTAssertEqual(repeatedUploads,1)

        let (downloads, uploadBytes) = await wire.counters()
        XCTAssertEqual(downloads,1,"Style updates across polls must reuse the verified vector PDF")
        XCTAssertLessThan(uploadBytes, original.record!.snapshotData!.count / 10,"Repetitive PDF data should use lossless wire compression")
        var fresh = SharedReviewAPI(origin:sender.origin,token:"test",displayName:"Receiver",instanceID:"fresh")
        fresh.transport = { try await wire.request($0) }
        do { _ = try await receiver.resolveSnapshots([.init(seq:20,op_type:"drawbridge.markup.v1",payload:uploaded)],document:"another-document",session:"other-session"); XCTFail("The cache must not leak a Snapshot across documents") } catch { }
        receiver.invalidate()
        do { _ = try await receiver.resolveSnapshots([.init(seq:21,op_type:"drawbridge.markup.v1",payload:uploaded)],document:"document",session:"other-session"); XCTFail("Logout must revoke access to cached Snapshot bytes") } catch { }
        await wire.setCorrupt()
        do { _ = try await fresh.resolveSnapshots([.init(seq:2,op_type:"drawbridge.markup.v1",payload:uploaded)],document:"document",session:"other-session"); XCTFail("Corrupt bytes must not advance replay") }
        catch { XCTAssertTrue(error.localizedDescription.contains("integrity")) }
        XCTAssertEqual(try outbox.load(),[edit])
    }
    func testRealHTTPServerUploadAppendAndSecondClientRestoration() async throws {
        guard let node = ProcessInfo.processInfo.environment["DRAWBRIDGE_NODE_TEST_EXECUTABLE"] else {
            throw XCTSkip("Opt-in private backend HTTP interoperability fixture")
        }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = project.appendingPathComponent("Backend/tests/snapshot-client-fixture.js")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("Private backend fixture unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let process=Process(); process.executableURL=URL(fileURLWithPath:node); process.arguments=[fixture.path,root.path]
        process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice
        var environment=ProcessInfo.processInfo.environment
        environment["PATH"]=project.appendingPathComponent(".build/release-v1.3.35/local-qa/Drawbridge Release QA.app/Contents/MacOS").path+":"+(environment["PATH"] ?? "")
        process.environment=environment
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() }; try? FileManager.default.removeItem(at:root) }
        let deadline=Date().addingTimeInterval(10), portFile=root.appendingPathComponent("port")
        while !FileManager.default.fileExists(atPath:portFile.path) && Date()<deadline && process.isRunning { try await Task.sleep(for:.milliseconds(20)) }
        let port=try String(contentsOf:portFile,encoding:.utf8)
        let origin=try XCTUnwrap(URL(string:"http://127.0.0.1:"+port))
        let sender=SharedReviewAPI(origin:origin,token:"sender",displayName:"Sender",instanceID:"sender")
        let receiver=SharedReviewAPI(origin:origin,token:"receiver",displayName:"Receiver",instanceID:"receiver")
        let original=try markup()
        let wire=try await sender.prepareSnapshot(original,document:"document",session:"session")
        let receipt:SharedReviewAPI.Receipt=try await sender.post("documents/document/ops",SharedReviewAPI.Append(sessionId:"session",clientOpId:"durable-op",payload:wire))
        XCTAssertEqual(receipt.op.payload?.snapshotAsset,wire.snapshotAsset)
        let fetched:SharedReviewAPI.Operations=try await receiver.get("documents/document/ops")
        let resolved=try await receiver.resolveSnapshots(fetched.ops,document:"document",session:"session")
        XCTAssertEqual(resolved.first?.payload,original)
        let annotation=try XCTUnwrap(resolved.first?.payload?.record).clipboardAnnotation(contents:nil,rotation:0)
        XCTAssertEqual(SnapshotPayload.read(annotation)?.data,original.record?.snapshotData)
    }
    func testPrivateArchitecturalSheetSnapshotRoundtrip() async throws {
        guard let path=ProcessInfo.processInfo.environment["DRAWBRIDGE_SNAPSHOT_SYNC_PDF"] else { throw XCTSkip("Opt-in private architectural PDF") }
        let document=try XCTUnwrap(PDFDocument(url:URL(fileURLWithPath:path))),page=try XCTUnwrap(document.page(at:document.pageCount-1))
        let bounds=page.bounds(for:.cropBox)
        let payload=try SnapshotPayload.capture(page:page,points:[CGPoint(x:bounds.minX,y:bounds.minY),CGPoint(x:bounds.maxX,y:bounds.minY),CGPoint(x:bounds.maxX,y:bounds.maxY),CGPoint(x:bounds.minX,y:bounds.maxY)])
        var record=try XCTUnwrap(markup().record);record.snapshotData=payload.data
        let original=SharedReviewAPI.Markup(id:record.id,page:0,record:record,ownerInstanceId:"sender")
        let wire=Wire();var api=SharedReviewAPI(origin:URL(string:"https://offline.invalid")!,token:"test",displayName:"Tester",instanceID:"sender")
        api.transport={try await wire.request($0)}
        let uploaded=try await api.prepareSnapshot(original,document:"document",session:"session")
        let result=try await api.resolveSnapshots([.init(seq:1,op_type:"drawbridge.markup.v1",payload:uploaded)],document:"document",session:"session")
        XCTAssertEqual(result.first?.payload?.record?.snapshotData,payload.data)
        XCTAssertTrue(SharedReviewAPI.canSync(record))
        let (_, compressedUploadBytes) = await wire.counters()
        print("ARCH_SNAPSHOT_SYNC uploadBytes=\(compressedUploadBytes) pdfBytes=\(payload.data.count) inlineRecordBytes=\(try JSONEncoder().encode(record).count) usedAsset=\(uploaded.snapshotAsset != nil)")
    }
    func testLargeSnapshotIsAdmittedButLargeNonSnapshotMetadataIsRejected() throws {
        let snapshot = try XCTUnwrap(markup().record)
        XCTAssertTrue(SharedReviewAPI.canSync(snapshot))
        var oversized = snapshot; oversized.kind = .text; oversized.snapshotData = nil; oversized.text = String(repeating:"x",count:1_600_000)
        XCTAssertFalse(SharedReviewAPI.canSync(oversized))
        XCTAssertFalse(SharedReviewAPI.SnapshotAsset(sha256:"../escape",byteCount:1).isValid)
    }
}
