import Foundation
import CryptoKit
import Security

/// Authentication is explicitly initiated in Settings; no discovery on startup.
@MainActor struct ReviewGoogleSignIn {
    typealias Transport = (URLRequest) async throws -> Data
    struct Configuration: Decodable {
        struct Google: Decodable { let clientId: String }
        let google: Google?
        let passwordLoginEnabled: Bool?
        var allowsPassword: Bool { google == nil && passwordLoginEnabled == true }
        func googleClientID() throws -> String {
            guard let id = google?.clientId.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                throw SharedReviewError("Google sign-in is not configured on this server. Contact your administrator.")
            }
            return id
        }
    }
    struct Attempt {
        let state: String
        let nonce: String
        let verifier: String
        var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
        init() throws {
            state = try Self.random(); nonce = try Self.random(); verifier = try Self.random()
        }
        private static func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        private static func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw SharedReviewError("Could not securely start Google sign-in.")
            }
            return base64URL(Data(bytes))
        }
        func validateNonce(in idToken: String) throws {
            // Correlation only: these unverified claims never establish identity or authorization.
            // The Review server remains responsible for signature, issuer, audience and time checks.
            let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
            guard segments.count == 3 else { throw SharedReviewError("Invalid Google identity token.") }
            var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let data = Data(base64Encoded: payload),
                  let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let returnedNonce = claims["nonce"] as? String, returnedNonce == nonce else {
                throw SharedReviewError("Google sign-in nonce did not match. Try again.")
            }
        }
        func authorizationURL(clientID: String, redirect: URL) throws -> URL {
            guard !clientID.isEmpty else { throw SharedReviewError("Missing Google Desktop client ID.") }
            var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            parts.queryItems = ["client_id": clientID, "redirect_uri": redirect.absoluteString,
                "response_type": "code", "scope": "openid email profile", "state": state,
                "nonce": nonce, "code_challenge": challenge, "code_challenge_method": "S256"]
                .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            return parts.url!
        }
        func code(from callback: URL, redirect: URL) throws -> String {
            guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                  parts.scheme == redirect.scheme, parts.host == redirect.host, parts.port == redirect.port,
                  parts.path == redirect.path, parts.user == nil, parts.password == nil, parts.fragment == nil else {
                throw SharedReviewError("Invalid Google sign-in callback destination.")
            }
            let items = parts.queryItems ?? []
            guard Set(items.map(\.name)).count == items.count,
                  items.first(where: { $0.name == "state" })?.value == state,
                  !items.contains(where: { $0.name == "error" }),
                  let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                throw SharedReviewError("Google sign-in was canceled or its security state did not match. Try again.")
            }
            return code
        }
    }
    let transport: Transport
    static func origin(_ text: String) throws -> URL {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, var parts = URLComponents(string: text.contains("://") ? text : "https://" + text),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/"].contains(parts.path) else {
            throw SharedReviewError("Enter an HTTPS Review server origin with no path, query, or credentials.")
        }
        parts.scheme = "https"; parts.path = ""
        guard let url = parts.url else { throw SharedReviewError("Invalid Review server origin.") }
        return url
    }
    static func liveTransport(_ request: URLRequest) async throws -> Data {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SharedReviewError("Sign-in request was rejected or is unsupported by this server. Contact your administrator.", statusCode: (response as? HTTPURLResponse)?.statusCode)
        }
        return data
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
    }
    func configuration(origin: URL) async throws -> Configuration {
        _ = try Self.origin(origin.absoluteString)
        let request = URLRequest(url: origin.appendingPathComponent("v1/auth/config"), timeoutInterval: 15)
        return try JSONDecoder().decode(Configuration.self, from: await transport(request))
    }
    func exchange(origin: URL, idToken: String, deviceKey: String) async throws -> SettingsWindowController.ServerSession {
        _ = try Self.origin(origin.absoluteString)
        guard !idToken.isEmpty, !deviceKey.isEmpty else { throw SharedReviewError("Missing Google identity or device key.") }
        var request = URLRequest(url: origin.appendingPathComponent("v1/auth/google"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["idToken": idToken, "deviceKey": deviceKey])
        let session = try JSONDecoder().decode(SettingsWindowController.ServerSession.self, from: await transport(request))
        guard !session.token.isEmpty, !session.instanceId.isEmpty,
              let name = session.displayName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SharedReviewError("The server did not return a verified Review identity.")
        }
        return session
    }
    func idToken(code: String, clientID: String, redirect: URL, attempt: Attempt) async throws -> String {
        var fields = ["code": code, "client_id": clientID, "redirect_uri": redirect.absoluteString,
                      "grant_type": "authorization_code", "code_verifier": attempt.verifier]
        // Some Google Desktop clients require their distributed client secret. Never embed one.
        if let secret = ProcessInfo.processInfo.environment["DRAWBRIDGE_GOOGLE_CLIENT_SECRET"], !secret.isEmpty {
            fields["client_secret"] = secret
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 30)
        request.httpMethod = "POST"; request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        struct Response: Decodable { let id_token: String }
        let response = try JSONDecoder().decode(Response.self, from: await transport(request))
        guard !response.id_token.isEmpty else { throw SharedReviewError("Google returned no identity token.") }
        // Do not decode identity claims here. Only the verified server response owns user identity.
        return response.id_token
    }
}
