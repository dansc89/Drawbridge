import Foundation

@MainActor
final class MainThreadWatchdog {
    private var timer: Timer?
    private var lastTickAt: Date = Date()
    private var enabled: Bool
    private var thresholdSeconds: Double
    private let onStall: (Double) -> Void

    init(enabled: Bool, thresholdSeconds: Double, onStall: @escaping (Double) -> Void) {
        self.enabled = enabled
        self.thresholdSeconds = max(0.5, thresholdSeconds)
        self.onStall = onStall
    }

    func start() {
        guard timer == nil else { return }
        lastTickAt = Date()
        timer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(handleTimerTick), userInfo: nil, repeats: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func update(enabled: Bool, thresholdSeconds: Double) {
        self.enabled = enabled
        self.thresholdSeconds = max(0.5, thresholdSeconds)
    }

    @objc private func handleTimerTick() {
        let now = Date()
        let gap = now.timeIntervalSince(lastTickAt)
        lastTickAt = now
        guard enabled else { return }
        if gap > thresholdSeconds {
            onStall(gap)
        }
    }
}
