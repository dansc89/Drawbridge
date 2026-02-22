import Foundation

@MainActor
final class DocumentPersistenceCoordinator {
    private let autosaveInterval: TimeInterval
    private var pendingAutosaveWorkItem: DispatchWorkItem?
    private(set) var autosaveInFlight = false
    private(set) var autosaveQueued = false
    private(set) var manualSaveInFlight = false

    init(autosaveInterval: TimeInterval) {
        self.autosaveInterval = autosaveInterval
    }

    var isManualSaveInFlight: Bool { manualSaveInFlight }

    func resetState() {
        pendingAutosaveWorkItem?.cancel()
        pendingAutosaveWorkItem = nil
        autosaveInFlight = false
        autosaveQueued = false
        manualSaveInFlight = false
    }

    func beginManualSave() {
        pendingAutosaveWorkItem?.cancel()
        pendingAutosaveWorkItem = nil
        autosaveQueued = false
        manualSaveInFlight = true
    }

    func endManualSave(rescheduleIfQueued: () -> Void) {
        manualSaveInFlight = false
        if autosaveQueued {
            autosaveQueued = false
            rescheduleIfQueued()
        }
    }

    func scheduleAutosaveIfNeeded(
        canAutosave: Bool,
        hasChanges: Bool,
        performAutosave: @escaping @MainActor () -> Void
    ) {
        guard canAutosave else {
            pendingAutosaveWorkItem?.cancel()
            pendingAutosaveWorkItem = nil
            autosaveQueued = false
            return
        }
        guard hasChanges else {
            pendingAutosaveWorkItem?.cancel()
            pendingAutosaveWorkItem = nil
            return
        }
        guard !manualSaveInFlight else {
            autosaveQueued = true
            return
        }

        pendingAutosaveWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            Task { @MainActor in
                performAutosave()
            }
        }
        pendingAutosaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveInterval, execute: workItem)
    }

    func beginAutosaveRun(canRun: Bool) -> Bool {
        pendingAutosaveWorkItem?.cancel()
        pendingAutosaveWorkItem = nil
        guard canRun, !manualSaveInFlight, !autosaveInFlight else {
            return false
        }
        autosaveInFlight = true
        return true
    }

    func finishAutosaveRun(stillHasChanges: Bool, reschedule: () -> Void) {
        autosaveInFlight = false
        if autosaveQueued || stillHasChanges {
            autosaveQueued = false
            reschedule()
        }
    }
}
