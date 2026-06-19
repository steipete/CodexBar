import CodexBarCore
import Foundation

/// Tracks what the main thread is currently doing so hang reports can name the
/// operation even when the stall happens in uninstrumented code.
enum MainThreadActivityBreadcrumb {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var stack: [String] = []
    }

    private static let state = State()

    static var current: String? {
        guard MainThreadHangWatchdog.isEnabledForCurrentProcess else { return nil }
        return self.state.lock.withLock { self.state.stack.last }
    }

    static func push(_ label: String) {
        guard MainThreadHangWatchdog.isEnabledForCurrentProcess else { return }
        self.state.lock.withLock {
            self.state.stack.append(label)
        }
    }

    static func pop() {
        guard MainThreadHangWatchdog.isEnabledForCurrentProcess else { return }
        self.state.lock.withLock {
            _ = self.state.stack.popLast()
        }
    }
}

/// Detects main-queue response delays and records breadcrumbs for the work that
/// occupied the main thread. Long hangs launch `/usr/bin/sample` asynchronously
/// so sampling cannot delay recovery detection or inflate the reported duration.
final class MainThreadHangWatchdog: @unchecked Sendable {
    static let shared = MainThreadHangWatchdog()
    static let isEnabledForCurrentProcess: Bool = {
        #if DEBUG
        true
        #else
        let environment = ProcessInfo.processInfo.environment
        return environment["CODEXBAR_MAIN_THREAD_HANG_WATCHDOG"] == "1" ||
            UserDefaults.standard.bool(forKey: "debugMainThreadHangWatchdog")
        #endif
    }()

    private let logger = CodexBarLog.logger(LogCategories.app)
    private let pingInterval: TimeInterval
    private let hangThreshold: TimeInterval
    private let sampleThreshold: TimeInterval
    private let sampleCooldown: TimeInterval
    private let sampleCaptureOverride: (@Sendable () -> String?)?
    private let schedulePing: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private var isRunning = false
    private var lastSampleAt: Date?
    private var activeSampleProcesses: [ObjectIdentifier: Process] = [:]
    var onHangForTesting: ((TimeInterval, [String]) -> Void)?
    #if DEBUG
    var onHangDetectionForTesting: (() -> Void)?
    private var onSampleAttemptForTesting: (() -> Void)?
    #endif

    private enum SampleCaptureResult {
        case coolingDown
        case attempted(String?)
    }

    init(
        pingInterval: TimeInterval = 0.025,
        hangThreshold: TimeInterval = 0.15,
        sampleThreshold: TimeInterval = 2.0,
        sampleCooldown: TimeInterval = 300,
        sampleCaptureOverride: (@Sendable () -> String?)? = nil,
        schedulePing: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { response in
            DispatchQueue.main.async(execute: response)
        })
    {
        self.pingInterval = pingInterval
        self.hangThreshold = hangThreshold
        self.sampleThreshold = sampleThreshold
        self.sampleCooldown = sampleCooldown
        self.sampleCaptureOverride = sampleCaptureOverride
        self.schedulePing = schedulePing
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
        self.lock.withLock {
            self.isRunning = false
        }
    }

    private var shouldRun: Bool {
        self.lock.withLock { self.isRunning }
    }

    private final class PingBox: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var _respondedAt: DispatchTime?

        func markResponded() {
            self.lock.withLock {
                self._respondedAt = .now()
            }
            self.semaphore.signal()
        }

        var respondedAt: DispatchTime? {
            self.lock.withLock { self._respondedAt }
        }

        func waitForResponse(timeout: TimeInterval) -> Bool {
            self.semaphore.wait(timeout: .now() + timeout) == .success
        }
    }

    private func run() {
        while self.shouldRun {
            let box = PingBox()
            let pingSentAt = DispatchTime.now()
            self.schedulePing { box.markResponded() }
            if !box.waitForResponse(timeout: self.hangThreshold) {
                guard self.shouldRun else { return }
                #if DEBUG
                self.onHangDetectionForTesting?()
                #endif
                self.traceHang(box: box, pingSentAt: pingSentAt)
            }
            guard self.shouldRun else { return }
            Thread.sleep(forTimeInterval: self.pingInterval)
        }
    }

    private func traceHang(box: PingBox, pingSentAt: DispatchTime) {
        // One delayed ping can span several main-thread operations, so retain each
        // distinct breadcrumb observed until the queued ping finally executes.
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
        var didAttemptSample = false
        while box.respondedAt == nil, self.shouldRun {
            recordActivity()
            if !didAttemptSample, self.elapsedSeconds(since: pingSentAt) >= self.sampleThreshold {
                #if DEBUG
                self.onSampleAttemptForTesting?()
                #endif
                switch self.captureSampleIfAllowed() {
                case .coolingDown:
                    break
                case let .attempted(file):
                    didAttemptSample = true
                    sampleFile = file
                }
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        guard let respondedAt = box.respondedAt else { return }
        let duration = self.elapsedSeconds(from: pingSentAt, to: respondedAt)
        var metadata: [String: String] = [
            "durationMs": String(format: "%.0f", duration * 1000),
            "activity": activities.isEmpty ? "unknown" : activities.joined(separator: ","),
        ]
        if let sampleFile {
            metadata["sampleRequested"] = sampleFile
        }
        self.logger.warning("main thread hang", metadata: metadata)
        self.onHangForTesting?(duration, activities)
    }

    private func elapsedSeconds(since start: DispatchTime) -> TimeInterval {
        self.elapsedSeconds(from: start, to: .now())
    }

    private func elapsedSeconds(from start: DispatchTime, to end: DispatchTime) -> TimeInterval {
        TimeInterval(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    private func captureSampleIfAllowed() -> SampleCaptureResult {
        let now = Date()
        let shouldCapture = self.lock.withLock {
            if self.lastSampleAt.map({ now.timeIntervalSince($0) < self.sampleCooldown }) ?? false {
                return false
            }
            self.lastSampleAt = now
            return true
        }
        guard shouldCapture else { return .coolingDown }

        let file = if let sampleCaptureOverride {
            sampleCaptureOverride()
        } else {
            self.launchSample()
        }
        return .attempted(file)
    }

    private func launchSample() -> String? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CodexBar", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            self.logger.warning(
                "main thread hang sample failed",
                metadata: ["error": "\(error)"])
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = directory.appendingPathComponent("hang-sample-\(stamp).txt")

        let process = Process()
        let processID = ObjectIdentifier(process)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "3", "-file", file.path]
        process.terminationHandler = { [weak self] completedProcess in
            self?.sampleDidFinish(completedProcess, processID: processID, file: file)
        }
        self.lock.withLock {
            self.activeSampleProcesses[processID] = process
        }
        do {
            try process.run()
        } catch {
            _ = self.lock.withLock {
                self.activeSampleProcesses.removeValue(forKey: processID)
            }
            self.logger.warning(
                "main thread hang sample failed",
                metadata: ["error": "\(error)"])
            return nil
        }
        return file.path
    }

    private func sampleDidFinish(_ process: Process, processID: ObjectIdentifier, file: URL) {
        _ = self.lock.withLock {
            self.activeSampleProcesses.removeValue(forKey: processID)
        }
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: file.path)
        else {
            self.logger.warning(
                "main thread hang sample failed",
                metadata: ["status": "\(process.terminationStatus)"])
            return
        }
        self.logger.info(
            "main thread hang sample captured",
            metadata: ["sample": file.path])
    }

    #if DEBUG
    func traceHangForTesting(
        responseDelay: TimeInterval,
        waitForSampleAttempt: Bool = false,
        responseBeforeTrace: Bool = false)
    {
        self.lock.withLock {
            self.isRunning = true
        }
        defer {
            self.lock.withLock {
                self.isRunning = false
            }
            self.onSampleAttemptForTesting = nil
        }

        let box = PingBox()
        let pingSentAt = DispatchTime.now()
        let scheduleResponse = {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + responseDelay) {
                box.markResponded()
            }
        }
        if responseBeforeTrace {
            Thread.sleep(forTimeInterval: responseDelay)
            box.markResponded()
        } else if waitForSampleAttempt {
            self.onSampleAttemptForTesting = scheduleResponse
        } else {
            scheduleResponse()
        }
        self.traceHang(box: box, pingSentAt: pingSentAt)
    }
    #endif
}
