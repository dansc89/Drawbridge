import Foundation

// Client-side integration boundary only. No wire format or authentication mechanism is implied.
struct ReviewVerifiedParticipant: Equatable, Sendable {
    let workspaceID: String
    let authenticatedUserID: String
    let verifiedName: String

    // Only an authenticated workspace membership adapter may supply these values.
    // This validates shape, NOT authenticity; never construct from markup author/device preferences.
    init?(workspaceID: String, authenticatedUserID: String, verifiedName: String) {
        guard [workspaceID, authenticatedUserID, verifiedName].allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        self.workspaceID = workspaceID
        self.authenticatedUserID = authenticatedUserID
        self.verifiedName = verifiedName
    }
}

struct ReviewParticipantHeartbeat: Sendable {
    let workspaceID: String
    let userID: String
    let sessionID: String
    let receivedAt: Date
    let isSyncing: Bool
    var monotonicDeadline: TimeInterval? = nil
}

struct ReviewParticipants: Sendable {
    enum Connection: Sendable { case unavailable, disconnected, connected, requiresReauthentication }
    enum RosterCoverage: Sendable { case unknown, complete, partial(requiresReauthenticationCount: Int) }
    enum State: String, Sendable { case online = "Online", offline = "Offline", syncing = "Syncing" }
    struct Row: Equatable, Sendable {
        let participant: ReviewVerifiedParticipant
        let state: State
    }
    let workspaceID: String
    let members: [ReviewVerifiedParticipant]
    let heartbeats: [ReviewParticipantHeartbeat]
    let connection: Connection
    var rosterCoverage: RosterCoverage = .unknown
    var freshnessDeadline: TimeInterval? = nil
    var isFresh: Bool { freshnessDeadline.map { ProcessInfo.processInfo.systemUptime < $0 } ?? true }
    // Local receipt time, not an untrusted remote device's wall clock.
    // The transport must retire a snapshot on disconnect and replace it on reconnect.
    static let heartbeatTimeout: TimeInterval = 30

    private var roster: [ReviewVerifiedParticipant] {
        var seen = Set<String>()
        return members.filter {
            $0.workspaceID == workspaceID && seen.insert($0.authenticatedUserID).inserted
        }.sorted {
            if $0.verifiedName != $1.verifiedName { return $0.verifiedName < $1.verifiedName }
            return $0.authenticatedUserID < $1.authenticatedUserID
        }
    }

    var participantCount: Int? { connection == .connected && isFresh ? roster.count : nil }

    func rows(at now: Date) -> [Row] {
        guard connection == .connected && isFresh else { return [] }
        return roster.map { participant in
            let sessions = Dictionary(grouping: heartbeats.filter {
                $0.workspaceID == workspaceID && $0.userID == participant.authenticatedUserID &&
                    !$0.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }, by: \.sessionID)
            let live = sessions.values.compactMap { $0.max { $0.receivedAt < $1.receivedAt } }.filter {
                if let deadline = $0.monotonicDeadline { return ProcessInfo.processInfo.systemUptime < deadline }
                let age = now.timeIntervalSince($0.receivedAt)
                return age >= 0 && age < Self.heartbeatTimeout
            }
            let state: State = live.isEmpty ? .offline : (live.contains { $0.isSyncing } ? .syncing : .online)
            return Row(participant: participant, state: state)
        }
    }

    func onlineCount(at now: Date) -> Int? {
        guard connection == .connected && isFresh else { return nil }
        return rows(at: now).filter { $0.state != .offline }.count
    }

    func summary(at now: Date) -> String {
        if connection == .connected && !isFresh { return "Disconnected — participant presence unknown." }
        switch connection {
        case .unavailable: return "Participant presence unavailable."
        case .disconnected: return "Disconnected — participant presence unknown."
        case .requiresReauthentication:
            return "Sign in again with Google under Settings → Drawbridge Review to enable verified participant presence."
        case .connected:
            let count = participantCount ?? 0
            let prefix = "\(onlineCount(at: now) ?? 0) online · \(count) verified participants"
            switch rosterCoverage {
            case .unknown: return prefix + " — roster coverage unknown."
            case .partial(let missing):
                return prefix + " — partial roster; \(missing) members must sign in again with Google."
            case .complete:
                return count == 0 ? "No participants in this workspace." : "\(onlineCount(at: now) ?? 0) online · \(count) workspace participants"
            }
        }
    }
}
