import Foundation

/// Converts server lease *remaining lifetime*, never roster fetch time, to local deadlines.
struct ReviewPresenceReceipt: Sendable {
    let wire: SharedReviewAPI.PresenceSnapshot
    let requestStarted: TimeInterval
    let received: TimeInterval
    let referenceDate = Date()
    static let freshness: TimeInterval = 15

    init(wire: SharedReviewAPI.PresenceSnapshot, workspaceID: String,
         requestStarted: TimeInterval, received: TimeInterval) throws {
        guard wire.version == 1, wire.workspaceId == workspaceID, wire.ttlSeconds == 30,
              received >= requestStarted, wire.members.count <= 10000, wire.leases.count <= 640000,
              Set(wire.members.map(\.userId)).count == wire.members.count,
              wire.members.allSatisfy({ ReviewVerifiedParticipant(workspaceID: workspaceID,
                  authenticatedUserID: $0.userId, verifiedName: $0.verifiedName) != nil }),
              wire.leases.allSatisfy({ lease in lease.remainingSeconds.isFinite && lease.remainingSeconds > 0 &&
                  lease.remainingSeconds <= wire.ttlSeconds && !lease.sessionId.isEmpty &&
                  wire.members.contains(where: { member in member.userId == lease.userId }) }) else {
            throw SharedReviewError("Unsupported or invalid verified workspace presence response.")
        }
        self.wire = wire; self.requestStarted = requestStarted; self.received = received
    }

    func snapshot(at uptime: TimeInterval) -> ReviewParticipants {
        guard uptime >= received, uptime - requestStarted < Self.freshness else {
            return .init(workspaceID: wire.workspaceId, members: [], heartbeats: [], connection: .disconnected)
        }
        let members = wire.members.compactMap {
            ReviewVerifiedParticipant(workspaceID: wire.workspaceId, authenticatedUserID: $0.userId, verifiedName: $0.verifiedName)
        }
        // Subtract the ENTIRE request round-trip conservatively. No device clocks are trusted.
        let elapsed = uptime - requestStarted
        let heartbeats: [ReviewParticipantHeartbeat] = wire.leases.compactMap { lease in
            let remaining = lease.remainingSeconds - elapsed
            guard remaining > 0 else { return nil }
            return .init(workspaceID: wire.workspaceId, userID: lease.userId, sessionID: lease.sessionId,
                         receivedAt: Date().addingTimeInterval(remaining - 30), isSyncing: false,
                         monotonicDeadline: ProcessInfo.processInfo.systemUptime + remaining)
        }
        var result = ReviewParticipants(workspaceID: wire.workspaceId, members: members,
                                        heartbeats: heartbeats, connection: .connected)
        result.freshnessDeadline = ProcessInfo.processInfo.systemUptime + max(0, Self.freshness - elapsed)
        if let coverage = wire.rosterCoverage, coverage.requiresReauthenticationCount >= 0 {
            result.rosterCoverage = coverage.complete && coverage.requiresReauthenticationCount == 0
                ? .complete : .partial(requiresReauthenticationCount: coverage.requiresReauthenticationCount)
        }
        return result
    }
}

/// Browser-owned; independent of document sync. Every replacement retires the previous generation.
@MainActor
final class ReviewWorkspacePresence {
    var onChange: ((ReviewParticipants?) -> Void)?
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var generation = UUID()
    private var api: SharedReviewAPI?
    private var workspaceID: String?
    private var connectionID = UUID().uuidString
    private var sequence = 0
    private var receipt: ReviewPresenceReceipt?
    private var requiresReauthentication = false
    private let pollInterval: Duration
    private let tickInterval: Duration

    init(pollInterval: Duration = .seconds(10), tickInterval: Duration = .seconds(1)) {
        self.pollInterval = pollInterval; self.tickInterval = tickInterval
    }
    deinit { pollTask?.cancel(); tickTask?.cancel() }

    func start(api: SharedReviewAPI, workspaceID: String) {
        if self.api?.origin == api.origin, self.api?.token == api.token,
           self.workspaceID == workspaceID, pollTask != nil || requiresReauthentication { return }
        stop()
        self.api = api; self.workspaceID = workspaceID
        connectionID = UUID().uuidString; sequence = 0
        let current = generation
        publishUnknown(.disconnected)
        let pollInterval = pollInterval, tickInterval = tickInterval
        pollTask = Task { [weak self] in
            // Only synchronous helpers may promote the owner. Neither the network
            // request nor either sleep holds it alive, so deinit can cancel both loops.
            defer { self?.pollFinished(generation: current) }
            while !Task.isCancelled {
                guard let request = self?.nextRequest(generation: current) else { return }
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    let wire = try await api.presence(workspaceID: workspaceID,
                        connectionID: request.connectionID, sequence: request.sequence)
                    try Task.checkCancellation()
                    try self?.accept(wire, workspaceID: workspaceID, started: started, generation: current)
                } catch {
                    guard !Task.isCancelled,
                          self?.failed(error, generation: current) == true else { return }
                }
                do { try await Task.sleep(for: pollInterval) } catch { return }
            }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: tickInterval) } catch { return }
                guard self?.tick(generation: current) == true else { return }
            }
        }
    }

    private func nextRequest(generation: UUID) -> (connectionID: String, sequence: Int)? {
        guard self.generation == generation else { return nil }
        sequence += 1
        return (connectionID, sequence)
    }

    private func accept(_ wire: SharedReviewAPI.PresenceSnapshot, workspaceID: String,
                        started: TimeInterval, generation: UUID) throws {
        guard self.generation == generation else { return }
        receipt = try ReviewPresenceReceipt(wire: wire, workspaceID: workspaceID,
            requestStarted: started, received: ProcessInfo.processInfo.systemUptime)
        tick()
    }

    private func failed(_ error: Error, generation: UUID) -> Bool {
        guard self.generation == generation else { return false }
        receipt = nil
        if let error = error as? SharedReviewError, error.statusCode == 403,
           error.code == "presence_reauthentication_required" {
            requiresReauthentication = true
            tickTask?.cancel(); tickTask = nil
            publishUnknown(.requiresReauthentication)
            return false
        }
        if let error = error as? SharedReviewError, [404,405,501].contains(error.statusCode ?? 0) {
            pollTask = nil
            tickTask?.cancel(); tickTask = nil
            publishUnknown(.unavailable)
            return false
        }
        publishUnknown(.disconnected)
        return true
    }

    private func pollFinished(generation: UUID) {
        // An old cancelled task must never clear a replacement generation's handle.
        guard self.generation == generation else { return }
        pollTask = nil
    }

    private func tick(generation: UUID) -> Bool {
        guard self.generation == generation else { return false }
        tick()
        return true
    }

    func stop() {
        generation = UUID()
        pollTask?.cancel(); pollTask = nil
        tickTask?.cancel(); tickTask = nil
        if let api, let workspaceID, !requiresReauthentication {
            let connectionID = connectionID, sequence = sequence + 1
            // Best effort independent lease leave. Signout may invalidate this API
            // before the task runs; never bypass revocation to send it. The server's
            // bounded 30s lease TTL is the fallback for signout/crashes/deallocation.
            Task { _ = try? await api.presence(workspaceID: workspaceID, connectionID: connectionID, sequence: sequence, leave: true) }
        }
        api = nil; workspaceID = nil; receipt = nil
        requiresReauthentication = false
        onChange?(nil)
    }

    private func tick() {
        guard let receipt else { return }
        onChange?(receipt.snapshot(at: ProcessInfo.processInfo.systemUptime))
    }
    private func publishUnknown(_ connection: ReviewParticipants.Connection) {
        onChange?(.init(workspaceID: workspaceID ?? "", members: [], heartbeats: [], connection: connection))
    }
}
