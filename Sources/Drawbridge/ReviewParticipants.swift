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
}

struct ReviewParticipants: Sendable {
    enum Connection: Sendable { case unavailable, disconnected, connected }
    enum State: String, Sendable { case online = "Online", offline = "Offline", syncing = "Syncing" }
    struct Row: Equatable, Sendable {
        let participant: ReviewVerifiedParticipant
        let state: State
    }
    let workspaceID: String
    let members: [ReviewVerifiedParticipant]
    let heartbeats: [ReviewParticipantHeartbeat]
    let connection: Connection
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

    var participantCount: Int? { connection == .connected ? roster.count : nil }

    func rows(at now: Date) -> [Row] {
        guard connection == .connected else { return [] }
        return roster.map { participant in
            let sessions = Dictionary(grouping: heartbeats.filter {
                $0.workspaceID == workspaceID && $0.userID == participant.authenticatedUserID &&
                    !$0.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }, by: \.sessionID)
            let live = sessions.values.compactMap { $0.max { $0.receivedAt < $1.receivedAt } }.filter {
                let age = now.timeIntervalSince($0.receivedAt)
                return age >= 0 && age < Self.heartbeatTimeout
            }
            let state: State = live.isEmpty ? .offline : (live.contains { $0.isSyncing } ? .syncing : .online)
            return Row(participant: participant, state: state)
        }
    }

    func onlineCount(at now: Date) -> Int? {
        guard connection == .connected else { return nil }
        return rows(at: now).filter { $0.state != .offline }.count
    }

    func summary(at now: Date) -> String {
        switch connection {
        case .unavailable: return "Participant presence unavailable."
        case .disconnected: return "Disconnected — participant presence unknown."
        case .connected:
            guard let count = participantCount, count > 0 else { return "No participants in this workspace." }
            return "\(onlineCount(at: now) ?? 0) online · \(count) workspace participants"
        }
    }
}
