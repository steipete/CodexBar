import AppKit
import CodexBarCore
import Foundation

#if DEBUG
/// Tracks what the main thread is currently doing so hang reports can name the
/// operation even when the stall happens in uninstrumented code.
enum MainThreadActivityBreadcrumb {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var stack: [String] = []
    }

    private static let state = State()

    static var current: String? {
        self.state.lock.lock()
        defer { self.state.lock.unlock() }
        return self.state.stack.last
    }

    static func push(_ label: String) {
        self.state.lock.lock()
        defer { self.state.lock.unlock() }
        self.state.stack.append(label)
    }

    static func pop() {
        self.state.lock.lock()
        defer { self.state.lock.unlock() }
        _ = self.state.stack.popLast()
    }
}

/// Detects main-thread stalls regardless of where they originate. A utility thread
/// pings the main queue and measures how long each ping waits; stalls above the
/// threshold are logged with the active breadcrumb, and long hangs additionally
/// capture a `/usr/bin/sample` of the process so the guilty stack lands in
/// ~/Library/Logs/CodexBar without anyone having to reproduce under a profiler.
/// Only started in DEBUG builds; release builds never spawn the watchdog thread.
final class MainThreadHangWatchdog: @unchecked Sendable {
    static let shared = MainThreadHangWatchdog()

    private let logger = CodexBarLog.logger(LogCategories.app)
    private let pingInterval: TimeInterval
    private let hangThreshold: TimeInterval
    private let sampleThreshold: TimeInterval
    private let sampleCooldown: TimeInterval
    private let lock = NSLock()
    private var isRunning = false
    private var lastSampleAt: Date?
    var onHangForTesting: ((TimeInterval, [String]) -> Void)?
    var onBeforePingForTesting: (() -> Void)?
    var onPingScheduledForTesting: (() -> Void)?

    init(
        pingInterval: TimeInterval = 0.5,
        hangThreshold: TimeInterval = 0.15,
        sampleThreshold: TimeInterval = 2.0,
        sampleCooldown: TimeInterval = 300)
    {
        self.pingInterval = pingInterval
        self.hangThreshold = hangThreshold
        self.sampleThreshold = sampleThreshold
        self.sampleCooldown = sampleCooldown
    }

    func start() {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.isRunning else { return }
        self.isRunning = true
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "CodexBar.MainThreadHangWatchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() {
        self.lock.lock()
        self.isRunning = false
        self.lock.unlock()
    }

    private var shouldRun: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.isRunning
    }

    private final class PingBox: @unchecked Sendable {
        private let lock = NSLock()
        private var responded = false

        func markResponded() {
            self.lock.lock()
            self.responded = true
            self.lock.unlock()
        }

        var hasResponded: Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.responded
        }
    }

    private func run() {
        while self.shouldRun {
            self.onBeforePingForTesting?()
            let box = PingBox()
            let pingSentAt = DispatchTime.now()
            DispatchQueue.main.async { box.markResponded() }
            self.onPingScheduledForTesting?()
            Thread.sleep(forTimeInterval: self.hangThreshold)
            guard self.shouldRun else { return }
            if !box.hasResponded {
                self.traceHang(box: box, pingSentAt: pingSentAt)
            }
            Thread.sleep(forTimeInterval: self.pingInterval)
        }
    }

    private func traceHang(box: PingBox, pingSentAt: DispatchTime) {
        // A single stall can span several pieces of main-thread work (runloop sources and
        // timers interleave ahead of the queued ping), so sample the breadcrumb throughout
        // the hang and report every distinct activity observed.
        var activities: [String] = []
        func recordActivity() {
            guard activities.count < 8,
                  let activity = MainThreadActivityBreadcrumb.current,
                  !activities.contains(activity)
            else { return }
            activities.append(activity)
        }

        recordActivity()
        var sampleFile: String?
        while !box.hasResponded, self.shouldRun {
            recordActivity()
            if sampleFile == nil, self.elapsedSeconds(since: pingSentAt) >= self.sampleThreshold {
                sampleFile = self.captureSampleIfAllowed()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard box.hasResponded else { return }
        let duration = self.elapsedSeconds(since: pingSentAt)
        var metadata: [String: String] = [
            "durationMs": String(format: "%.0f", duration * 1000),
            "activity": activities.isEmpty ? "unknown" : activities.joined(separator: ","),
        ]
        if let sampleFile {
            metadata["sample"] = sampleFile
        }
        self.logger.warning("main thread hang", metadata: metadata)
        self.onHangForTesting?(duration, activities)
    }

    private func elapsedSeconds(since start: DispatchTime) -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    private func captureSampleIfAllowed() -> String? {
        self.lock.lock()
        if let last = self.lastSampleAt, Date().timeIntervalSince(last) < self.sampleCooldown {
            self.lock.unlock()
            return nil
        }
        self.lastSampleAt = Date()
        self.lock.unlock()

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CodexBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = directory.appendingPathComponent("hang-sample-\(stamp).txt")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "3", "-file", file.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            self.logger.warning(
                "main thread hang sample failed",
                metadata: ["error": "\(error)"])
            return nil
        }
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: file.path)
        else {
            self.logger.warning(
                "main thread hang sample failed",
                metadata: ["status": "\(process.terminationStatus)"])
            return nil
        }
        return file.path
    }
}
#endif
