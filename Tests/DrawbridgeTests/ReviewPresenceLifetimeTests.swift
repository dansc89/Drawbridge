import Foundation
import XCTest
@testable import Drawbridge

/// Dedicated owner/task lifetime regressions; no browser or document controller ownership.
final class ReviewPresenceLifetimeTests: XCTestCase {
    @MainActor
    private func api() -> SharedReviewAPI {
        SharedReviewAPI(origin: URL(string: "https://example.invalid")!, token: "test",
                        displayName: nil, instanceID: "device")
    }

    private static let snapshot = Data(#"{"version":1,"workspaceId":"w","ttlSeconds":30,"members":[{"userId":"a","verifiedName":"Ada"}],"leases":[],"onlineCount":0}"#.utf8)

    @MainActor
    func testSleepingPollAndTickDoNotRetainOwnerOrKeepHeartbeating() async throws {
        var api = api()
        var calls = 0
        api.transport = { request in
            calls += 1
            return (Self.snapshot, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        var owner: ReviewWorkspacePresence? = ReviewWorkspacePresence(pollInterval: .milliseconds(30), tickInterval: .milliseconds(10))
        weak var weakOwner = owner
        owner?.start(api: api, workspaceID: "w")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertGreaterThan(calls, 0)
        owner = nil
        XCTAssertNil(weakOwner, "Neither sleeping loop may promote weak self across an await")
        let stoppedAt = calls
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls, stoppedAt, "Dropping the owner must stop future heartbeats without explicit stop")
    }

    @MainActor
    func testSuspendedNetworkDoesNotRetainOwnerAndLateResponseDoesNotPublish() async throws {
        var api = api()
        var pending: CheckedContinuation<Void, Never>?
        var publications = 0
        api.transport = { request in
            await withCheckedContinuation { pending = $0 }
            return (Self.snapshot, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        var owner: ReviewWorkspacePresence? = ReviewWorkspacePresence()
        weak var weakOwner = owner
        owner?.onChange = { _ in publications += 1 }
        owner?.start(api: api, workspaceID: "w")
        for _ in 0..<100 where pending == nil { await Task.yield() }
        XCTAssertNotNil(pending)
        owner = nil
        XCTAssertNil(weakOwner, "An in-flight transport must not own the presence owner")
        let stoppedAt = publications
        pending?.resume()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(publications, stoppedAt)
    }

    @MainActor
    func testSameAPIStartRetriesCompletedUnsupportedPoll() async throws {
        for status in [404, 405, 501] {
            var api = api()
            var supported = false
            var calls = 0
            api.transport = { request in
                calls += 1
                return (supported ? Self.snapshot : Data(), HTTPURLResponse(url: request.url!, statusCode: supported ? 200 : status, httpVersion: nil, headerFields: nil)!)
            }
            let owner = ReviewWorkspacePresence(pollInterval: .seconds(60))
            var connection: ReviewParticipants.Connection?
            owner.onChange = { connection = $0?.connection }
            owner.start(api: api, workspaceID: "w")
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(connection, .unavailable)
            XCTAssertEqual(calls, 1)
            supported = true
            owner.start(api: api, workspaceID: "w")
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(connection, .connected, "Explicit start must retry after server gains presence support")
            owner.stop()
        }
    }

    @MainActor
    func testRetiredPollCompletionCannotClearReplacementTask() async throws {
        var oldAPI = api()
        var pending: CheckedContinuation<Void, Never>?
        oldAPI.transport = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            if body["leave"] as? Bool != true {
                await withCheckedContinuation { pending = $0 }
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        var newAPI = SharedReviewAPI(origin: oldAPI.origin, token: "replacement", displayName: nil, instanceID: "device")
        var newCalls = 0
        newAPI.transport = { request in
            newCalls += 1
            return (Self.snapshot, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let owner = ReviewWorkspacePresence(pollInterval: .seconds(60))
        var connection: ReviewParticipants.Connection?
        owner.onChange = { connection = $0?.connection }
        owner.start(api: oldAPI, workspaceID: "w")
        for _ in 0..<100 where pending == nil { await Task.yield() }
        XCTAssertNotNil(pending)
        owner.start(api: newAPI, workspaceID: "w")
        try await Task.sleep(for: .milliseconds(20))
        pending?.resume()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(connection, .connected)
        owner.start(api: newAPI, workspaceID: "w")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(newCalls, 1, "Retired task cleanup must not erase the active replacement handle")
        owner.stop()
    }

    @MainActor
    func testSameAPIStartWhilePollingIsIdempotent() async throws {
        var api = api()
        var calls = 0
        api.transport = { request in
            calls += 1
            return (Self.snapshot, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let owner = ReviewWorkspacePresence(pollInterval: .seconds(60))
        owner.start(api: api, workspaceID: "w")
        try await Task.sleep(for: .milliseconds(20))
        owner.start(api: api, workspaceID: "w")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(calls, 1)
        owner.stop()
    }
}
