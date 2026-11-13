import AppKit
import XCTest
@testable import Drawbridge

@MainActor final class ReviewSessionHardeningTests: XCTestCase {
    typealias Settings = SettingsWindowController
    let origin = URL(string: "https://review.example.com")!
    let session = Settings.ServerSession(token: "offline-token", instanceId: "offline-instance", displayName: "Verified Name")
    final class MemoryStore { var data: Data?; var reads = 0; var writes = 0; var locked = false; var failWrite = false }

    func isolated(_ body: @MainActor (MemoryStore, UserDefaults) async throws -> Void) async throws {
        let oldDefaults = Settings.reviewSessionDefaults
        let oldRead = Settings.reviewSessionRead, oldWrite = Settings.reviewSessionWrite, oldDelete = Settings.reviewSessionDelete
        let oldActive = Settings.activeReviewSession, oldAttempted = Settings.attemptedSessionRestore
        let suite = "ReviewSessionHardeningTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let store = MemoryStore()
        Settings.reviewSessionDefaults = defaults
        Settings.activeReviewSession = nil
        Settings.attemptedSessionRestore = false
        Settings.reviewSessionRead = { store.reads += 1; if store.locked { throw URLError(.noPermissionsToReadFile) }; return store.data }
        Settings.reviewSessionWrite = { data in store.writes += 1; if store.failWrite { return false }; store.data = data; return true }
        // Failed delete intentionally leaves the item present.
        Settings.reviewSessionDelete = {}
        defer {
            Settings.reviewSessionDefaults = oldDefaults
            Settings.reviewSessionRead = oldRead; Settings.reviewSessionWrite = oldWrite; Settings.reviewSessionDelete = oldDelete
            Settings.activeReviewSession = oldActive; Settings.attemptedSessionRestore = oldAttempted
            defaults.removePersistentDomain(forName: suite)
        }
        try await body(store, defaults)
    }
    func restart() { Settings.activeReviewSession = nil; Settings.attemptedSessionRestore = false }
    func testPersistenceBindsOriginInEnvelopeAndRoundTrips() async throws {
        try await isolated { store, _ in
            XCTAssertTrue(try Settings.persistReviewSession(origin: self.origin, session: self.session))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(store.data)) as? [String: Any])
            XCTAssertEqual(object["origin"] as? String, self.origin.absoluteString)
            XCTAssertNotNil(object["session"])
            self.restart()
            let (origin, session) = try Settings.sharedReviewCredentials()
            XCTAssertEqual(origin, self.origin); XCTAssertEqual(session.token, self.session.token)
        }
    }
    func testChangedPreferencesCannotRedirectRestoredBearer() async throws {
        try await isolated { _, defaults in
            try Settings.persistReviewSession(origin: self.origin, session: self.session)
            defaults.set("https://other.example.com", forKey: "sharedServerDomain")
            self.restart()
            XCTAssertThrowsError(try Settings.sharedReviewCredentials(), "must not disclose saved bearer to changed origin")
            XCTAssertNil(Settings.activeReviewSession)
        }
    }
    func testLegacyUnboundSessionFailsClosed() async throws {
        try await isolated { store, defaults in
            store.data = try JSONEncoder().encode(self.session)
            defaults.set(self.origin.absoluteString, forKey: "sharedServerDomain")
            XCTAssertThrowsError(try Settings.sharedReviewCredentials(), "legacy entries have no authenticated origin")
        }
    }
    func testStrictRestoreRejectsPathQueryCredentialsAndMalformedSession() async throws {
        try await isolated { store, defaults in
            for domain in ["https://review.example.com/path", "https://review.example.com?q=x", "https://user@review.example.com", "https://review.example.com#x", "http://review.example.com"] {
                try Settings.persistReviewSession(origin: self.origin, session: self.session)
                defaults.set(domain, forKey: "sharedServerDomain")
                self.restart()
                XCTAssertThrowsError(try Settings.sharedReviewCredentials(), domain)
            }
            defaults.set(self.origin.absoluteString, forKey: "sharedServerDomain")
            for bad in [Settings.ServerSession(token: "", instanceId: "i", displayName: "Name"), .init(token: "t", instanceId: " ", displayName: "Name"), .init(token: "t", instanceId: "i", displayName: " "), .init(token: "t", instanceId: "i", displayName: nil)] {
                // Encode the intended bound schema directly so malformed persisted bytes reach restore.
                let data = try JSONEncoder().encode(bad)
                let value = try JSONSerialization.jsonObject(with: data)
                store.data = try JSONSerialization.data(withJSONObject: ["version": 1, "origin": self.origin.absoluteString, "session": value])
                self.restart()
                XCTAssertThrowsError(try Settings.sharedReviewCredentials())
            }
        }
    }
    func testLockedReadFailedWriteAndFailedDeleteRemainSuppressedAcrossRestart() async throws {
        try await isolated { store, defaults in
            try Settings.persistReviewSession(origin: self.origin, session: self.session)
            store.locked = true
            XCTAssertThrowsError(try Settings.sharedReviewCredentials())
            store.locked = false
            XCTAssertThrowsError(try Settings.sharedReviewCredentials(), "only attempt restore once per launch")
            store.failWrite = true
            XCTAssertFalse(try Settings.persistReviewSession(origin: self.origin, session: self.session))
            self.restart()
            XCTAssertThrowsError(try Settings.sharedReviewCredentials())
            Settings.activeReviewSession = (self.origin, self.session)
            SettingsWindowController(editor: MainViewController()).signOutOfServer()
            XCTAssertNotNil(store.data, "failed deletion must not invalidate this suppression test")
            XCTAssertTrue(defaults.bool(forKey: "DrawbridgeSkipReviewSessionRestore"))
            self.restart()
            let before = store.reads
            XCTAssertThrowsError(try Settings.sharedReviewCredentials())
            XCTAssertEqual(store.reads, before, "restart suppression must precede Keychain read")
        }
    }
    func testLogoutRejectsDelayedSignInBeforeDeviceKeyOrExchange() async throws {
        try await isolated { _, _ in
            let settings = Settings(editor: MainViewController())
            var continuation: CheckedContinuation<String, Never>?
            let entered = expectation(description: "identity provider entered")
            var paths: [String] = []
            settings.reviewAuthTransport = { request in
                paths.append(request.url!.path)
                return Data((request.url!.path == "/v1/auth/config" ? #"{"google":{"clientId":"offline-client"}}"# : #"{"token":"offline-token","instanceId":"i","displayName":"Name"}"#).utf8)
            }
            settings.reviewGoogleIdentityToken = { _ in
                await withCheckedContinuation { continuation = $0; entered.fulfill() }
            }
            settings.reviewDeviceKey = { _, _ in XCTFail("stale login must not touch device Keychain"); return "offline-key" }
            let task = Task { try await settings.reviewSignIn(origin: self.origin, useGoogle: true, username: "", password: "", markupAuthor: "") }
            await fulfillment(of: [entered], timeout: 2)
            settings.signOutOfServer()
            continuation?.resume(returning: "offline-id-token")
            do { _ = try await task.value; XCTFail("logout must reject delayed identity result") } catch {}
            XCTAssertEqual(paths, ["/v1/auth/config"])
            XCTAssertNil(Settings.activeReviewSession)
        }
    }
}
