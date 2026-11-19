import XCTest
@testable import Drawbridge

@MainActor final class ReviewSessionRenewalTests: XCTestCase {
    func testConcurrentRequestsRenewOncePersistAndRejectLateSignoutCompletion() async throws {
        let origin = URL(string: "https://review.example.com")!
        let oldSession = SettingsWindowController.activeReviewSession
        let oldWrite = SettingsWindowController.reviewSessionWrite
        let oldTransport = ReviewSessionRenewal.transport
        let oldDefaults = SettingsWindowController.reviewSessionDefaults
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        SettingsWindowController.reviewSessionDefaults = defaults
        defer {
            SettingsWindowController.activeReviewSession = oldSession
            SettingsWindowController.reviewSessionWrite = oldWrite
            SettingsWindowController.reviewSessionDefaults = oldDefaults
            ReviewSessionRenewal.transport = oldTransport
        }
        var writes = 0, calls = 0
        SettingsWindowController.reviewSessionWrite = { _ in writes += 1; return true }
        let expired = SettingsWindowController.ServerSession(token:"expired",instanceId:"user",displayName:"Verified User",workspaceIdentity:true,refreshToken:"refresh",expiresAt:0)
        SettingsWindowController.activeReviewSession = (origin,expired)
        ReviewSessionRenewal.transport = { request in
            calls += 1
            XCTAssertEqual(request.url?.path,"/v1/auth/refresh")
            try await Task.sleep(for:.milliseconds(20))
            return Data(#"{"token":"renewed","instanceId":"user","displayName":"Verified User","workspaceIdentity":true,"refreshToken":"refresh","expiresAt":9999999999}"#.utf8)
        }
        async let first = ReviewSessionRenewal.credentials(origin:origin,instanceID:"user",fallback:"expired")
        async let second = ReviewSessionRenewal.credentials(origin:origin,instanceID:"user",fallback:"expired")
        let results = try await [first,second]
        XCTAssertEqual(results,["renewed","renewed"])
        XCTAssertEqual(calls,1)
        XCTAssertGreaterThan(writes,0)
        XCTAssertEqual(SettingsWindowController.activeReviewSession?.session.token,"renewed")
        let other = try await ReviewSessionRenewal.credentials(origin:origin,instanceID:"other",fallback:"other-token")
        XCTAssertEqual(other,"other-token")
        SettingsWindowController.activeReviewSession = (origin,expired)
        ReviewSessionRenewal.transport = { _ in
            SettingsWindowController.activeReviewSession = nil
            return Data(#"{"token":"late","instanceId":"user","displayName":"Verified User","workspaceIdentity":true,"refreshToken":"refresh","expiresAt":9999999999}"#.utf8)
        }
        do { _ = try await ReviewSessionRenewal.credentials(origin:origin,instanceID:"user",fallback:"expired"); XCTFail("logout must win") }
        catch is CancellationError {}
        XCTAssertNil(SettingsWindowController.activeReviewSession)
    }
}
