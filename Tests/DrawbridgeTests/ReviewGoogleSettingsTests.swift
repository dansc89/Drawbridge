import XCTest
import AppKit
@testable import Drawbridge

@MainActor final class ReviewGoogleSettingsTests: XCTestCase {
    let origin = URL(string: "https://review.example.com")!
    func testSettingsSignInUsesDiscoveryBrowserServerExchangeAndVerifiedIdentity() async throws {
        let settings = SettingsWindowController(editor: MainViewController())
        var paths: [String] = [], browserIDs: [String] = []
        settings.reviewAuthTransport = { request in
            paths.append(request.url!.path)
            switch request.url!.path {
            case "/v1/auth/config": return Data(#"{"google":{"clientId":"desktop-client"}}"#.utf8)
            case "/v1/auth/google":
                let body = try JSONDecoder().decode([String:String].self, from: XCTUnwrap(request.httpBody))
                XCTAssertEqual(body, ["idToken":"id-token", "deviceKey":"fake-device-key"])
                return Data(#"{"token":"app-token","instanceId":"instance","displayName":"Server Verified Name"}"#.utf8)
            default: XCTFail("Unexpected request"); throw URLError(.badURL)
            }
        }
        settings.reviewGoogleIdentityToken = { id in browserIDs.append(id); return "id-token" }
        settings.reviewDeviceKey = { server, account in
            XCTAssertEqual(server, self.origin)
            XCTAssertEqual(account, "google-sso")
            return "fake-device-key"
        }
        let result = try await settings.reviewSignIn(origin: origin, useGoogle: true, username: "untrusted-login", password: "never-send", markupAuthor: "Untrusted Author")
        XCTAssertEqual(paths, ["/v1/auth/config", "/v1/auth/google"])
        XCTAssertEqual(browserIDs, ["desktop-client"])
        XCTAssertEqual(result.displayName, "Server Verified Name")
    }
    func testPasswordCannotBypassConfiguredGoogleOrUnknownConfiguration() async throws {
        for config in [#"{"google":{"clientId":"desktop-client"},"passwordLoginEnabled":true}"#, "{}"] {
            let settings = SettingsWindowController(editor: MainViewController())
            var paths: [String] = []
            settings.reviewAuthTransport = { request in paths.append(request.url!.path); return Data(config.utf8) }
            settings.reviewDeviceKey = { _, _ in XCTFail("must reject before Keychain"); return "key" }
            do {
                _ = try await settings.reviewSignIn(origin: origin, useGoogle: false, username: "name", password: "password", markupAuthor: "author")
                XCTFail("password must fail closed")
            } catch {}
            XCTAssertEqual(paths, ["/v1/auth/config"])
        }
    }
    func testMissingGoogleClientIDNeverStartsBrowserOrTouchesKeychain() async throws {
        for config in ["{}", #"{"google":{"clientId":" "}}"#] {
            let settings = SettingsWindowController(editor: MainViewController())
            settings.reviewAuthTransport = { _ in Data(config.utf8) }
            settings.reviewGoogleIdentityToken = { _ in XCTFail("No configured client"); return "id" }
            settings.reviewDeviceKey = { _, _ in XCTFail("No configured client"); return "key" }
            do { _ = try await settings.reviewSignIn(origin: origin, useGoogle: true, username: "", password: "", markupAuthor: ""); XCTFail("must reject") } catch {}
        }
    }
    func testNonceMustMatchAttemptBeforeServerExchange() throws {
        let attempt = try ReviewGoogleSignIn.Attempt()
        func token(_ nonce: String) -> String {
            let data = try! JSONEncoder().encode(["nonce":nonce, "name":"Never trust this name"])
            let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "header.\(payload).signature"
        }
        XCTAssertNoThrow(try attempt.validateNonce(in: token(attempt.nonce)))
        XCTAssertThrowsError(try attempt.validateNonce(in: token("wrong")))
        XCTAssertThrowsError(try attempt.validateNonce(in: "not-a-jwt"))
    }
    func testLoopbackReceivesOnlyLocalHTTPCallback() async throws {
        let listener = try ReviewOAuthLoopback(timeout: 5)
        XCTAssertEqual(listener.redirect.host, "127.0.0.1")
        let receive = Task { try await listener.callback() }
        var parts = URLComponents(url: listener.redirect, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "state", value: "state"), URLQueryItem(name: "code", value: "code")]
        let localSession = URLSession(configuration: .ephemeral)
        defer { localSession.invalidateAndCancel(); listener.cancel() }
        let (_, response) = try await localSession.data(from: parts.url!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let callback = try await receive.value
        XCTAssertEqual(callback, parts.url)
    }
    func testLoopbackTimeoutAndCancellationAreBounded() async throws {
        let listener = try ReviewOAuthLoopback(timeout: 0.05)
        do { _ = try await listener.callback(); XCTFail("must time out") } catch {}
        let canceled = try ReviewOAuthLoopback(timeout: 5)
        canceled.cancel()
        do { _ = try await canceled.callback(); XCTFail("must cancel") } catch {}
    }
}
