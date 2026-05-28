import CodexBarCore
import Foundation

@MainActor
final class MainRunLoopStallMonitor {
    private let logger: CodexBarLogger
    private let interval: TimeInterval
    private let threshold: TimeInterval
    private let metadataProvider: @MainActor () -> [String: String]
    private var timer: DispatchSourceTimer?
    private var lastTick: TimeInterval = ProcessInfo.processInfo.systemUptime

    init(
        logger: CodexBarLogger,
        interval: TimeInterval = 0.1,
        threshold: TimeInterval = 0.35,
        metadataProvider: @escaping @MainActor () -> [String: String])
    {
        self.logger = logger
        self.interval = interval
        self.threshold = threshold
        self.metadataProvider = metadataProvider
    }

    func start() {
        guard self.timer == nil else { return }

        self.lastTick = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + self.interval,
            repeating: self.interval,
            leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        self.timer?.cancel()
        self.timer = nil
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - self.lastTick
        self.lastTick = now

        let gap = max(0, elapsed - self.interval)
        guard gap >= self.threshold else { return }

        var metadata = self.metadataProvider()
        metadata["elapsedMs"] = String(format: "%.1f", elapsed * 1000)
        metadata["gapMs"] = String(format: "%.1f", gap * 1000)
        metadata["thresholdMs"] = String(format: "%.1f", self.threshold * 1000)
        self.logger.warning("main runloop stall detected", metadata: metadata)
    }

    deinit {
        self.timer?.cancel()
    }
}
