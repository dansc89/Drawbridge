import XCTest
import CryptoKit
@testable import Drawbridge

@MainActor final class ReviewGoogleSignInTests: XCTestCase {
    let origin = URL(string: "https://review.example.com")!
    func testManualOriginRejectsMissingInsecureOrNonOriginInput() throws {
        for value in ["", "http://review.example.com", "https://user@review.example.com", "https://review.example.com/path", "https://review.example.com?q=x", "https://review.example.com#fragment"] {
            XCTAssertThrowsError(try ReviewGoogleSignIn.origin(value), value)
        }
        XCTAssertEqual(try ReviewGoogleSignIn.origin("https://review.example.com/"), origin)
    }
    func testDiscoveryUsesOnlyManualOriginAndDoesNotAuthorizePasswordByDefault() async throws {
        var requests: [URLRequest] = []
        let flow = ReviewGoogleSignIn { request in
            requests.append(request)
            return Data(#"{"google":{"clientId":"public-desktop-client.apps.googleusercontent.com"},"passwordLoginEnabled":true}"#.utf8)
        }
        let config = try await flow.configuration(origin: origin)
        XCTAssertEqual(requests.map(\.url?.absoluteString), ["https://review.example.com/v1/auth/config"])
        XCTAssertEqual(config.google?.clientId, "public-desktop-client.apps.googleusercontent.com")
        XCTAssertFalse(config.allowsPassword, "Google configured must never silently fall back to a password")
        let passwordOnly = try JSONDecoder().decode(ReviewGoogleSignIn.Configuration.self, from: Data(#"{"passwordLoginEnabled":true}"#.utf8))
        XCTAssertTrue(passwordOnly.allowsPassword)
        let missing = try JSONDecoder().decode(ReviewGoogleSignIn.Configuration.self, from: Data("{}".utf8))
        XCTAssertFalse(missing.allowsPassword)
    }
    func testPKCEUsesFreshRandomValuesAndGoogleAuthorizationEndpoint() throws {
        let first = try ReviewGoogleSignIn.Attempt(), second = try ReviewGoogleSignIn.Attempt()
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertNotEqual(first.verifier, second.verifier)
        XCTAssertGreaterThanOrEqual(first.verifier.count, 43)
        let expected = Data(SHA256.hash(data: Data(first.verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(first.challenge, expected)
        let url = try first.authorizationURL(clientID: "desktop-id", redirect: URL(string: "http://127.0.0.1:12345/oauth/callback")!)
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(parts.host, "accounts.google.com")
        XCTAssertEqual(parts.path, "/o/oauth2/v2/auth")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["code_challenge"], expected)
        XCTAssertEqual(query["state"], first.state)
        XCTAssertEqual(query["nonce"], first.nonce)
        XCTAssertEqual(query["scope"], "openid email profile")
    }
    func testCallbackRejectsWrongStateDuplicateParametersErrorsAndWrongDestination() throws {
        let attempt = try ReviewGoogleSignIn.Attempt()
        let redirect = URL(string: "http://127.0.0.1:12345/oauth/callback")!
        XCTAssertEqual(try attempt.code(from: URL(string: redirect.absoluteString + "?state=\(attempt.state)&code=accepted")!, redirect: redirect), "accepted")
        for suffix in ["?state=bad&code=x", "?state=\(attempt.state)&state=\(attempt.state)&code=x", "?state=\(attempt.state)&error=access_denied", "?state=\(attempt.state)&code="] {
            XCTAssertThrowsError(try attempt.code(from: URL(string: redirect.absoluteString + suffix)!, redirect: redirect))
        }
        XCTAssertThrowsError(try attempt.code(from: URL(string: "http://127.0.0.1:12346/oauth/callback?state=\(attempt.state)&code=x")!, redirect: redirect))
    }
    func testServerExchangeSendsOnlyIDTokenAndDeviceKeyAndUsesVerifiedServerName() async throws {
        var captured: URLRequest?
        let flow = ReviewGoogleSignIn { request in
            captured = request
            return Data(#"{"token":"app-session","instanceId":"server-device","displayName":"Verified Reviewer"}"#.utf8)
        }
        let session = try await flow.exchange(origin: origin, idToken: "google-id-token", deviceKey: "test-device-key")
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.path, "/v1/auth/google")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try JSONDecoder().decode([String:String].self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body, ["idToken":"google-id-token", "deviceKey":"test-device-key"])
        XCTAssertEqual(session.token, "app-session")
        XCTAssertEqual(session.displayName, "Verified Reviewer")
    }
    func testServerExchangeRejectsMissingVerifiedNameOrEmptySession() async throws {
        for json in [#"{"token":"app","instanceId":"device"}"#, #"{"token":"","instanceId":"device","displayName":"Name"}"#, #"{"token":"app","instanceId":"device","displayName":" "}"#] {
            let flow = ReviewGoogleSignIn { _ in Data(json.utf8) }
            do { _ = try await flow.exchange(origin: origin, idToken: "id", deviceKey: "key"); XCTFail("must fail closed") } catch {}
        }
    }
    func testGoogleTokenExchangeUsesVerifierWithoutTrustingUnverifiedTokenName() async throws {
        let attempt = try ReviewGoogleSignIn.Attempt()
        var request: URLRequest?
        let flow = ReviewGoogleSignIn { value in request = value; return Data(#"{"id_token":"opaque-server-must-verify"}"#.utf8) }
        let token = try await flow.idToken(code: "one+time&code", clientID: "desktop-id", redirect: URL(string: "http://127.0.0.1:12345/oauth/callback")!, attempt: attempt)
        XCTAssertEqual(token, "opaque-server-must-verify")
        XCTAssertEqual(request?.url?.absoluteString, "https://oauth2.googleapis.com/token")
        let body = String(data: try XCTUnwrap(request?.httpBody), encoding: .utf8)!
        XCTAssertTrue(body.contains("code_verifier=\(attempt.verifier)"))
        XCTAssertTrue(body.contains("code=one%2Btime%26code"))
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
    }
}
