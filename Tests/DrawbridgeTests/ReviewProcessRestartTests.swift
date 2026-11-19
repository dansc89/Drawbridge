import AppKit
import Security
import XCTest
@testable import Drawbridge

/// Opt-in qualification uses a unique Keychain item containing fake credentials.
/// Each phase is a separate OS process, with the production credential store.
@MainActor final class ReviewProcessRestartTests: XCTestCase {
    func testSavedLoginSurvivesProcessExitOfflineAndRenewal() throws {
        guard ProcessInfo.processInfo.environment["DRAWBRIDGE_RESTART_KEYCHAIN_QA"] == "1" else {
            throw XCTSkip("Set DRAWBRIDGE_RESTART_KEYCHAIN_QA=1 for isolated real-Keychain process restart qualification")
        }
        let identity = "com.drawbridge.restart-qa." + UUID().uuidString
        defer {
            UserDefaults.standard.removePersistentDomain(forName: identity)
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: identity, kSecAttrAccount: "session"] as CFDictionary)
        }
        for phase in ["save", "offline-restore", "renew", "renewed-restore", "logout", "signed-out-restore"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", "DrawbridgeTests.ReviewProcessRestartTests/testRestartChild", Bundle(for: Self.self).bundleURL.path]
            var environment = ProcessInfo.processInfo.environment
            environment["DRAWBRIDGE_RESTART_CHILD"] = phase
            environment["DRAWBRIDGE_RESTART_IDENTITY"] = identity
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output; process.standardError = output
            try process.run()
            // Drain while the child runs to avoid a filled output pipe.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "Restart phase \(phase): \(String(decoding: data, as: UTF8.self))")
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("RESTART_PHASE_VERIFIED:\(phase)"), "The child must execute the requested phase")
            guard process.terminationStatus == 0 else { return }
        }
    }

    func testRestartChild() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let phase = environment["DRAWBRIDGE_RESTART_CHILD"], let identity = environment["DRAWBRIDGE_RESTART_IDENTITY"] else {
            throw XCTSkip("Invoked only by the process restart qualification")
        }
        typealias Settings = SettingsWindowController
        Settings.serverKeychainService = identity
        Settings.reviewSessionDefaults = UserDefaults(suiteName: identity)!
        let origin = URL(string: "https://restart-qa.example.com")!
        XCTAssertNil(Settings.activeReviewSession)
        let expired = Settings.ServerSession(token: "fake-expired", instanceId: "fake-user", displayName: "Restart QA", workspaceIdentity: true, refreshToken: "fake-refresh", expiresAt: 0)
        switch phase {
        case "save":
            XCTAssertTrue(try Settings.persistReviewSession(origin: origin, session: expired))
        case "offline-restore":
            let restored = try Settings.sharedReviewCredentials()
            XCTAssertEqual(restored.0, origin)
            XCTAssertEqual(restored.1.token, expired.token)
            ReviewSessionRenewal.transport = { _ in throw URLError(.notConnectedToInternet) }
            do { _ = try await ReviewSessionRenewal.credentials(origin: origin, instanceID: "fake-user", fallback: expired.token); XCTFail("Expected offline") }
            catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
            XCTAssertEqual(try Settings.sharedReviewCredentials().1.refreshToken, "fake-refresh")
            XCTAssertFalse(Settings.reviewSessionDefaults.bool(forKey: "DrawbridgeSkipReviewSessionRestore"))
        case "renew":
            let restored = try Settings.sharedReviewCredentials()
            ReviewSessionRenewal.transport = { _ in
                let renewed = Settings.ServerSession(token: "fake-renewed", instanceId: "fake-user", displayName: "Restart QA", workspaceIdentity: true, refreshToken: "fake-refresh", expiresAt: 9999999999)
                return try JSONEncoder().encode(renewed)
            }
            let token = try await ReviewSessionRenewal.credentials(origin: origin, instanceID: "fake-user", fallback: restored.1.token)
            XCTAssertEqual(token, "fake-renewed")
        case "renewed-restore":
            XCTAssertEqual(try Settings.sharedReviewCredentials().1.token, "fake-renewed")
        case "logout":
            _ = try Settings.sharedReviewCredentials()
            SettingsWindowController(editor: MainViewController()).signOutOfServer()
        case "signed-out-restore":
            XCTAssertThrowsError(try Settings.sharedReviewCredentials())
        default: XCTFail("Unknown phase")
        }
        Settings.reviewSessionDefaults.synchronize()
        print("RESTART_PHASE_VERIFIED:\(phase)")
    }
}
