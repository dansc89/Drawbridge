import AppKit
import XCTest
@testable import Drawbridge

final class ReviewPresenceTests: XCTestCase {
    @MainActor
    func testCoverageIsExplicitAndLegacyCoverageRemainsUnknown() throws {
        _ = NSApplication.shared
        for (coverage, expected) in [("", "coverage unknown"), (",\"rosterCoverage\":{\"complete\":false,\"requiresReauthenticationCount\":2}", "2 members must sign in again with Google"), (",\"rosterCoverage\":{\"complete\":true,\"requiresReauthenticationCount\":0}", "workspace participants")] {
            let data = Data((#"{"version":1,"workspaceId":"w","ttlSeconds":30,"members":[{"userId":"a","verifiedName":"Trusted Ada"}],"leases":[],"onlineCount":0"# + coverage + "}").utf8)
            let wire = try JSONDecoder().decode(SharedReviewAPI.PresenceSnapshot.self, from: data)
            let snapshot = try ReviewPresenceReceipt(wire: wire, workspaceID: "w", requestStarted: 100, received: 100).snapshot(at: 100)
            XCTAssertTrue(snapshot.summary(at: Date()).contains(expected), snapshot.summary(at: Date()))
            XCTAssertEqual(snapshot.rows(at: Date()).first?.participant.verifiedName, "Trusted Ada")
            if !coverage.contains("true") { XCTAssertFalse(snapshot.summary(at: Date()).contains("workspace participants")) }
            let view = ReviewParticipantsView(frame: .zero)
            view.disclosureButton.performClick(nil)
            view.render(snapshot)
            XCTAssertEqual(view.summaryField.stringValue, snapshot.summary(at: Date()))
            if !coverage.contains("true") { XCTAssertTrue(view.disclosureButton.title.contains("verified")) }
        }
    }

    @MainActor
    func testReauthenticationStopsUnchangedCredentialsAndPreservesAPI() async throws {
        var calls = 0
        var api = SharedReviewAPI(origin: URL(string: "https://example.invalid")!, token: "old", displayName: "Untrusted", instanceID: "d")
        api.transport = { request in
            calls += 1
            return (Data(#"{"error":"Sign in again","code":"presence_reauthentication_required"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        let owner = ReviewWorkspacePresence(pollInterval: .milliseconds(10), tickInterval: .milliseconds(10))
        var snapshot: ReviewParticipants?
        owner.onChange = { snapshot = $0 }
        owner.start(api: api, workspaceID: "w")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(snapshot?.summary(at: Date()).contains("Settings → Drawbridge Review") == true)
        XCTAssertTrue(snapshot?.summary(at: Date()).contains("Google") == true)
        owner.start(api: api, workspaceID: "w")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(calls, 1)
        XCTAssertNoThrow(try api.checkActive())
        var fresh = SharedReviewAPI(origin: api.origin, token: "fresh", displayName: nil, instanceID: "d")
        fresh.transport = api.transport
        owner.start(api: fresh, workspaceID: "w")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertGreaterThan(calls, 1)
        owner.stop()
    }

    func testWireLeaseAgeDoesNotReviveAndSnapshotExpiresToUnknown() throws {
        let data = Data(#"{"version":1,"workspaceId":"w","ttlSeconds":30,"members":[{"userId":"a","verifiedName":"Ada"},{"userId":"b","verifiedName":"Bo"}],"leases":[{"userId":"a","sessionId":"one","remainingSeconds":3},{"userId":"a","sessionId":"two","remainingSeconds":5}],"onlineCount":1}"#.utf8)
        let wire = try JSONDecoder().decode(SharedReviewAPI.PresenceSnapshot.self, from: data)
        let receipt = try ReviewPresenceReceipt(wire: wire, workspaceID: "w", requestStarted: 100, received: 102)
        XCTAssertEqual(receipt.snapshot(at: 102).onlineCount(at: receipt.referenceDate), 1)
        XCTAssertEqual(receipt.snapshot(at: 106).onlineCount(at: receipt.referenceDate.addingTimeInterval(4)), 0)
        XCTAssertNil(receipt.snapshot(at: 118).onlineCount(at: receipt.referenceDate.addingTimeInterval(16)))
        XCTAssertThrowsError(try ReviewPresenceReceipt(wire: wire, workspaceID: "other", requestStarted: 100, received: 102))
    }

    @MainActor
    func testAdapterAndPollingWorkWithoutDocumentAndStopSuppressesLateResponse() async throws {
        var calls = 0
        var api = SharedReviewAPI(origin: URL(string:"https://example.invalid")!, token:"test", displayName:"Untrusted preference", instanceID:"device")
        api.transport = { request in
            XCTAssertEqual(request.url?.path, "/v1/projects/w/presence")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer test")
            XCTAssertEqual(request.httpMethod,"POST")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String:Any]
            XCTAssertNotNil(UUID(uuidString: body["connectionId"] as! String))
            XCTAssertNil(body["displayName"])
            calls += 1
            return (Data(#"{"version":1,"workspaceId":"w","ttlSeconds":30,"members":[{"userId":"a","verifiedName":"Verified Ada"}],"leases":[{"userId":"a","sessionId":"lease","remainingSeconds":30}],"onlineCount":1}"#.utf8), HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        let owner = ReviewWorkspacePresence(pollInterval: .milliseconds(20), tickInterval: .milliseconds(10))
        var snapshots: [ReviewParticipants?] = []
        owner.onChange = { snapshots.append($0) }
        owner.start(api:api, workspaceID:"w")
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertGreaterThan(calls, 1)
        XCTAssertEqual(snapshots.last??.onlineCount(at:Date()),1)
        owner.stop()
        let count = snapshots.count
        try await Task.sleep(for:.milliseconds(80))
        XCTAssertEqual(snapshots.count,count)
        XCTAssertNil(snapshots.last!)
    }

    @MainActor
    func testOldServerUnavailableAndNetworkFailureUnknown() async throws {
        for status in [404,503] {
            var api = SharedReviewAPI(origin:URL(string:"https://example.invalid")!,token:"test",displayName:nil,instanceID:"d")
            api.transport = { r in (Data(),HTTPURLResponse(url:r.url!,statusCode:status,httpVersion:nil,headerFields:nil)!) }
            let owner=ReviewWorkspacePresence(pollInterval:.milliseconds(20))
            var snapshot:ReviewParticipants?
            owner.onChange = { snapshot=$0 }
            owner.start(api:api,workspaceID:"w")
            try await Task.sleep(for:.milliseconds(70))
            XCTAssertEqual(snapshot?.connection,status == 404 ? .unavailable : .disconnected)
            XCTAssertNil(snapshot?.onlineCount(at:Date()))
            owner.stop()
        }
    }

    @MainActor
    func testPanelHeaderShowsOnlineWhileCollapsed() {
        _ = NSApplication.shared
        let view=ReviewParticipantsView(frame:.zero)
        let now=Date()
        let person=ReviewVerifiedParticipant(workspaceID:"w",authenticatedUserID:"a",verifiedName:"Ada")!
        view.disclosureButton.performClick(nil)
        view.render(.init(workspaceID:"w",members:[person],heartbeats:[.init(workspaceID:"w",userID:"a",sessionID:"s",receivedAt:now,isSyncing:false)],connection:.connected, rosterCoverage: .complete),at:now)
        XCTAssertTrue(view.bodyStack.isHidden)
        XCTAssertEqual(view.disclosureButton.title,"Participants · 1 online")
    }
}
