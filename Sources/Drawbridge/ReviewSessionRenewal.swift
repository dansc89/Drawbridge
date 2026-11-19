import Foundation

/// All windows share one renewal and retain their original account binding.
@MainActor enum ReviewSessionRenewal {
    private static var pending: (id: UUID, origin: URL, token: String, task: Task<SettingsWindowController.ServerSession, Error>)?
    private static var unsupportedOrigins: [URL: Date] = [:]
    static var transport: ReviewGoogleSignIn.Transport = ReviewGoogleSignIn.liveTransport

    static func credentials(origin: URL, instanceID: String, fallback: String, force: Bool = false) async throws -> String {
        guard let current = try? SettingsWindowController.sharedReviewCredentials(),
              current.0 == origin, current.1.instanceId == instanceID,
              current.1.workspaceIdentity == true else { return fallback }
        let old = current.1
        if !force, old.refreshToken == nil, let until = unsupportedOrigins[origin], until > Date() { return old.token }
        if force && old.token != fallback { return old.token }
        let expiry = old.expiresAt ?? tokenExpiry(old.token)
        guard force || old.refreshToken == nil || expiry.map({ $0 - Date().timeIntervalSince1970 < 120 }) == true else { return old.token }
        let renewal: (id: UUID, origin: URL, token: String, task: Task<SettingsWindowController.ServerSession, Error>)
        if let pending, pending.origin == origin, pending.token == old.token {
            renewal = pending
        } else {
            let task = Task {
                var request = URLRequest(url: origin.appendingPathComponent("v1/auth/refresh"), timeoutInterval: 20)
                request.httpMethod = "POST"
                request.setValue("Bearer " + old.token, forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(old.refreshToken.map { ["refreshToken": $0] } ?? [:])
                let data = try await transport(request)
                let next = try JSONDecoder().decode(SettingsWindowController.ServerSession.self, from: data)
                guard next.instanceId == old.instanceId, next.workspaceIdentity == true,
                      !next.token.isEmpty, next.refreshToken?.isEmpty == false else {
                    throw SharedReviewError("The server returned an invalid renewed session.")
                }
                return next
            }
            renewal = (UUID(), origin, old.token, task)
            pending = renewal
        }
        defer { if pending?.id == renewal.id { pending = nil } }
        do {
            let next = try await renewal.task.value
            try Task.checkCancellation()
            guard let active = SettingsWindowController.activeReviewSession,
                  active.origin == origin, active.session.instanceId == instanceID,
                  active.session.token == old.token || active.session.token == next.token else { throw CancellationError() }
            SettingsWindowController.activeReviewSession = (origin, next)
            _ = try SettingsWindowController.persistReviewSession(origin: origin, session: next, preservingSavedIdentity: true)
            return next.token
        } catch let error as SharedReviewError where [404, 405].contains(error.statusCode ?? 0) {
            unsupportedOrigins[origin] = Date().addingTimeInterval(300)
            // Older servers can keep using an existing valid access token.
            return old.token
        }
    }

    private static func tokenExpiry(_ token: String) -> Double? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value["exp"] as? Double
    }
}
