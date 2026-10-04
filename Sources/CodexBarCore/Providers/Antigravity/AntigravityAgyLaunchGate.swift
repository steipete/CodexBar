import Foundation
#if os(macOS) && canImport(Network)
@preconcurrency import AppKit
import Network
#endif

enum AntigravityNetworkPathStatus: Sendable, Equatable {
    case satisfied
    case unsatisfied
    case requiresConnection
}

struct AntigravityAgyLaunchReading: Sendable, Equatable {
    var status: AntigravityNetworkPathStatus
    var observedAt: Date
}

/// Shared decision for starting a new `agy`. An unstarted gate allows immediately so unit tests
/// and hosts that never install the monitor do not wait for a path.
public final class AntigravityAgyLaunchGate: @unchecked Sendable {
    static let shared = AntigravityAgyLaunchGate()
    static let initialReadingTimeout: Duration = .milliseconds(300)
    static let wakeSettleTimeout: Duration = .seconds(2)

    private let lock = NSLock()
    private var started = false
    private var reading: AntigravityAgyLaunchReading?
    private var wakeUnsettledAt: Date?
    private let initialReadingTimeout: Duration
    private let wakeSettleTimeout: Duration
    private var waits: [TrackedWait] = []
    private var isParked = false
    private var parkedEntryWaiters: [CheckedContinuation<Void, Never>] = []

    #if os(macOS) && canImport(Network)
    private var pathMonitor: NWPathMonitor?
    private var pathMonitorQueue: DispatchQueue?
    private nonisolated(unsafe) var wakeObserver: NSObjectProtocol?
    #endif

    init(
        initialReadingTimeout: Duration = AntigravityAgyLaunchGate.initialReadingTimeout,
        wakeSettleTimeout: Duration = AntigravityAgyLaunchGate.wakeSettleTimeout)
    {
        self.initialReadingTimeout = initialReadingTimeout
        self.wakeSettleTimeout = wakeSettleTimeout
    }

    public static func start() {
        #if os(macOS) && canImport(Network)
        self.shared.startMonitoring()
        #endif
    }

    static func authorize() async throws {
        try await self.shared.allowNewLaunch()
    }

    func markStarted() {
        self.lock.lock()
        self.started = true
        self.lock.unlock()
    }

    func notePath(_ status: AntigravityNetworkPathStatus, observedAt: Date) {
        let matched: [AntigravityAgyLaunchWait]
        self.lock.lock()
        self.reading = AntigravityAgyLaunchReading(status: status, observedAt: observedAt)
        matched = self.waits.compactMap { tracked in
            let matches = if let after = tracked.after {
                observedAt >= after
            } else {
                true
            }
            return matches ? tracked.wait : nil
        }
        self.lock.unlock()
        for wait in matched {
            self.complete(wait, .success(true))
        }
    }

    func noteWake(at date: Date) {
        self.lock.lock()
        self.wakeUnsettledAt = date
        self.lock.unlock()
    }

    func waitUntilParked() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            if self.isParked {
                self.lock.unlock()
                continuation.resume()
                return
            }
            self.parkedEntryWaiters.append(continuation)
            self.lock.unlock()
        }
    }

    func allowNewLaunch() async throws {
        while true {
            try Task.checkCancellation()
            switch self.outcome() {
            case .allow:
                return
            case .skip:
                throw URLError(.notConnectedToInternet)
            case let .wait(timeout, after):
                let updated = try await self.park(after: after, timeout: timeout)
                if updated { continue }
                try Task.checkCancellation()
                switch self.outcome() {
                case .allow:
                    return
                case .skip:
                    throw URLError(.notConnectedToInternet)
                case let .wait(_, stillAfter):
                    // No post-wake update must not trust a stale satisfied path.
                    if stillAfter != nil {
                        throw URLError(.notConnectedToInternet)
                    }
                    return
                }
            }
        }
    }

    #if os(macOS) && canImport(Network)
    func startMonitoring() {
        self.lock.lock()
        if self.started {
            self.lock.unlock()
            return
        }
        self.started = true
        self.lock.unlock()

        let queue = DispatchQueue(label: "com.steipete.codexbar.antigravity-network-path")
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.notePath(Self.status(of: path), observedAt: Date())
        }
        self.lock.lock()
        self.pathMonitor = monitor
        self.pathMonitorQueue = queue
        self.lock.unlock()
        monitor.start(queue: queue)
        self.installWakeObserver()
    }
    #endif

    private func outcome() -> Outcome {
        self.lock.lock()
        let started = self.started
        let reading = self.reading
        let wakeAt = self.wakeUnsettledAt
        let initialTimeout = self.initialReadingTimeout
        let wakeTimeout = self.wakeSettleTimeout
        self.lock.unlock()

        guard started else { return .allow }
        if let wakeAt {
            // A path that was satisfied before sleep can still look satisfied after wake.
            if let reading, reading.observedAt >= wakeAt {
                return self.outcome(for: reading.status)
            }
            return .wait(timeout: wakeTimeout, after: wakeAt)
        }
        if let reading {
            return self.outcome(for: reading.status)
        }
        return .wait(timeout: initialTimeout, after: nil)
    }

    private func outcome(for status: AntigravityNetworkPathStatus) -> Outcome {
        switch status {
        case .satisfied:
            .allow
        case .unsatisfied, .requiresConnection:
            .skip
        }
    }

    private func park(after: Date?, timeout: Duration) async throws -> Bool {
        if timeout <= .zero {
            return self.hasUpdate(after: after)
        }
        try Task.checkCancellation()
        let wait = AntigravityAgyLaunchWait()
        let timeoutTask = Task<Void, Never> { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.complete(wait, .success(false))
        }
        wait.setTimeoutTask(timeoutTask)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                guard wait.store(continuation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.register(wait, after: after)
            }
        } onCancel: { [weak self] in
            self?.complete(wait, .failure(CancellationError()))
        }
    }

    private func register(_ wait: AntigravityAgyLaunchWait, after: Date?) {
        if self.hasUpdate(after: after) {
            self.complete(wait, .success(true))
            return
        }
        var entryWaiters: [CheckedContinuation<Void, Never>] = []
        self.lock.lock()
        if self.hasUpdateUnlocked(after: after) {
            self.lock.unlock()
            self.complete(wait, .success(true))
            return
        }
        self.waits.append(TrackedWait(wait: wait, after: after))
        self.isParked = true
        entryWaiters = self.parkedEntryWaiters
        self.parkedEntryWaiters.removeAll()
        self.lock.unlock()
        if self.hasUpdate(after: after) {
            self.complete(wait, .success(true))
        }
        for entry in entryWaiters {
            entry.resume()
        }
    }

    private func complete(_ wait: AntigravityAgyLaunchWait, _ result: Result<Bool, Error>) {
        self.lock.lock()
        self.waits.removeAll { $0.wait === wait }
        self.isParked = !self.waits.isEmpty
        self.lock.unlock()
        guard let continuation = wait.finish(result) else { return }
        switch result {
        case let .success(value):
            continuation.resume(returning: value)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    private func hasUpdate(after: Date?) -> Bool {
        self.lock.lock()
        let matched = self.hasUpdateUnlocked(after: after)
        self.lock.unlock()
        return matched
    }

    private func hasUpdateUnlocked(after: Date?) -> Bool {
        guard let reading = self.reading else { return false }
        guard let after else { return true }
        return reading.observedAt >= after
    }

    #if os(macOS) && canImport(Network)
    private func installWakeObserver() {
        let install = {
            guard self.wakeObserver == nil else { return }
            self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil)
            { [weak self] _ in
                self?.noteWake(at: Date())
            }
        }
        if Thread.isMainThread {
            install()
        } else {
            DispatchQueue.main.sync(execute: install)
        }
    }

    private static func status(of path: NWPath) -> AntigravityNetworkPathStatus {
        switch path.status {
        case .satisfied:
            .satisfied
        case .unsatisfied:
            .unsatisfied
        case .requiresConnection:
            .requiresConnection
        @unknown default:
            .unsatisfied
        }
    }
    #endif

    private enum Outcome: Equatable {
        case allow
        case skip
        case wait(timeout: Duration, after: Date?)
    }

    private struct TrackedWait {
        let wait: AntigravityAgyLaunchWait
        let after: Date?
    }
}

private final class AntigravityAgyLaunchWait: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Error>?
    private var finished = false
    private var timeoutTask: Task<Void, Never>?

    func setTimeoutTask(_ task: Task<Void, Never>) {
        self.lock.lock()
        if self.finished {
            self.lock.unlock()
            task.cancel()
            return
        }
        self.timeoutTask = task
        self.lock.unlock()
    }

    func store(_ continuation: CheckedContinuation<Bool, Error>) -> Bool {
        self.lock.lock()
        if self.finished {
            self.lock.unlock()
            return false
        }
        self.continuation = continuation
        self.lock.unlock()
        return true
    }

    func finish(_: Result<Bool, Error>) -> CheckedContinuation<Bool, Error>? {
        self.lock.lock()
        if self.finished {
            self.lock.unlock()
            return nil
        }
        self.finished = true
        let continuation = self.continuation
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.lock.unlock()
        timeoutTask?.cancel()
        return continuation
    }
}
