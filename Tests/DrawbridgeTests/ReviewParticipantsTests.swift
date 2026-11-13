import AppKit
import XCTest
@testable import Drawbridge

final class ReviewParticipantsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private func member(_ id: String = "user-1", workspace: String = "workspace") -> ReviewVerifiedParticipant {
        ReviewVerifiedParticipant(workspaceID: workspace, authenticatedUserID: id, verifiedName: "Reviewer \(id)")!
    }
    private func heartbeat(_ id: String = "user-1", session: String = "device", age: Double = 0,
                           syncing: Bool = false, workspace: String = "workspace") -> ReviewParticipantHeartbeat {
        .init(workspaceID: workspace, userID: id, sessionID: session,
              receivedAt: now.addingTimeInterval(-age), isSyncing: syncing)
    }
    func testVerifiedIdentityRejectsBlankIdentifiersAndNames() {
        XCTAssertNil(ReviewVerifiedParticipant(workspaceID: " ", authenticatedUserID: "u", verifiedName: "Name"))
        XCTAssertNil(ReviewVerifiedParticipant(workspaceID: "w", authenticatedUserID: "\n", verifiedName: "Name"))
        XCTAssertNil(ReviewVerifiedParticipant(workspaceID: "w", authenticatedUserID: "u", verifiedName: " "))
    }
    func testUnavailableAndDisconnectedAreNotAnEmptyWorkspace() {
        for connection in [ReviewParticipants.Connection.unavailable, .disconnected] {
            let snapshot = ReviewParticipants(workspaceID: "workspace", members: [], heartbeats: [], connection: connection)
            XCTAssertNil(snapshot.participantCount)
            XCTAssertNil(snapshot.onlineCount(at: now))
            XCTAssertEqual(snapshot.rows(at: now), [])
            XCTAssertNotEqual(snapshot.summary(at: now), "No participants in this workspace.")
        }
        let empty = ReviewParticipants(workspaceID: "workspace", members: [], heartbeats: [], connection: .connected)
        XCTAssertEqual(empty.participantCount, 0)
        XCTAssertEqual(empty.onlineCount(at: now), 0)
        XCTAssertEqual(empty.summary(at: now), "No participants in this workspace.")
    }
    func testWorkspaceRosterIsUniqueAndIgnoresUnknownOrForeignHeartbeats() {
        let snapshot = ReviewParticipants(workspaceID: "workspace",
            members: [member(), member(), member("other", workspace: "foreign")],
            heartbeats: [heartbeat(workspace: "foreign"), heartbeat("unknown")], connection: .connected)
        XCTAssertEqual(snapshot.participantCount, 1)
        XCTAssertEqual(snapshot.rows(at: now).map(\.state), [.offline])
    }
    func testHeartbeatExpiresAtTimeoutAndSyncingDoesNotRemainOnlineForever() {
        let snapshot = ReviewParticipants(workspaceID: "workspace", members: [member()],
            heartbeats: [heartbeat(syncing: true)], connection: .connected)
        XCTAssertEqual(snapshot.rows(at: now).map(\.state), [.syncing])
        XCTAssertEqual(snapshot.onlineCount(at: now), 1)
        XCTAssertEqual(snapshot.rows(at: now.addingTimeInterval(29)).map(\.state), [.syncing])
        XCTAssertEqual(snapshot.rows(at: now.addingTimeInterval(30)).map(\.state), [.offline])
        XCTAssertEqual(snapshot.onlineCount(at: now.addingTimeInterval(30)), 0)
    }
    func testLatestHeartbeatPerSessionWinsAndOtherDevicesKeepUserOnline() {
        let snapshot = ReviewParticipants(workspaceID: "workspace", members: [member()],
            heartbeats: [heartbeat(age: 10, syncing: true), heartbeat(age: 2),
                         heartbeat(session: "second", age: 40, syncing: true)], connection: .connected)
        XCTAssertEqual(snapshot.rows(at: now).map(\.state), [.online])
        let secondDevice = ReviewParticipants(workspaceID: "workspace", members: [member()],
            heartbeats: [heartbeat(age: 40), heartbeat(session: "second", syncing: true)], connection: .connected)
        XCTAssertEqual(secondDevice.rows(at: now).map(\.state), [.syncing])
        XCTAssertEqual(secondDevice.participantCount, 1)
    }
    func testFutureHeartbeatsDoNotClaimOnlineStatus() {
        let snapshot = ReviewParticipants(workspaceID: "workspace", members: [member()],
            heartbeats: [heartbeat(age: -60)], connection: .connected)
        XCTAssertEqual(snapshot.rows(at: now).map(\.state), [.offline])
    }
}
