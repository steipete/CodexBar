#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

// MARK: - Antigravity CLI Process Abstractions

protocol AntigravityCLIProcessHandle: AnyObject, Sendable {
    var pid: pid_t { get }
    var isRunning: Bool { get }
    var processGroup: pid_t? { get }

    func assignProcessGroup() -> pid_t?
    func sendExit() throws
    func closePTY()
    func terminateRoot()
    func killRoot()
    func descendantPIDs() -> [pid_t]
    func terminateTree(signal: Int32, knownDescendants: [pid_t])
    func killDescendants(_ descendants: [pid_t])
    func drainOutput() -> Data
}

protocol AntigravityCLIProcessLaunching: Sendable {
    func launch(binary: String) throws -> any AntigravityCLIProcessHandle
}

enum AntigravityCLIAuthenticationPrompt {
    static let evidence = Data("Select login method:".utf8)
    private static let promptPattern = #"select\s+login\s+method\s*:?"#

    static func contains(_ output: Data) -> Bool {
        // `agy` briefly prints "You are currently not signed in" before it
        // auto-refreshes an existing login. The actual blocking state is the
        // interactive login-method prompt. The exact prompt is a CLI-owned TUI
        // string, so keep matching tolerant to casing and whitespace changes.
        if output.range(of: self.evidence) != nil {
            return true
        }
        let asciiBytes = output.map { $0 < 0x80 ? $0 : 0x20 }
        let text = String(bytes: asciiBytes, encoding: .utf8) ?? ""
        return text.range(
            of: self.promptPattern,
            options: [.regularExpression, .caseInsensitive]) != nil
    }
}

struct AntigravityCLIProcessIdentity: Equatable {
    let executablePath: String
    let startEpoch: TimeInterval
}

protocol AntigravityCLIProcessIdentityProviding: Sendable {
    func identity(for pid: pid_t) -> AntigravityCLIProcessIdentity?
}

struct AntigravityCLISessionRecord: Codable, Equatable {
    let pid: pid_t
    let requestedBinaryPath: String
    let executablePath: String
    let startEpoch: TimeInterval
    let processGroup: pid_t?
    let ownerPID: pid_t?
    let ownerExecutablePath: String?
    let ownerStartEpoch: TimeInterval?

    init(
        pid: pid_t,
        requestedBinaryPath: String,
        executablePath: String,
        startEpoch: TimeInterval,
        processGroup: pid_t?,
        ownerPID: pid_t? = nil,
        ownerExecutablePath: String? = nil,
        ownerStartEpoch: TimeInterval? = nil)
    {
        self.pid = pid
        self.requestedBinaryPath = requestedBinaryPath
        self.executablePath = executablePath
        self.startEpoch = startEpoch
        self.processGroup = processGroup
        self.ownerPID = ownerPID
        self.ownerExecutablePath = ownerExecutablePath
        self.ownerStartEpoch = ownerStartEpoch
    }
}

protocol AntigravityCLISessionRecordStoring: Sendable {
    func load() throws -> [AntigravityCLISessionRecord]
    func save(_ record: AntigravityCLISessionRecord) throws
    func remove(_ record: AntigravityCLISessionRecord) throws
}

protocol AntigravityCLISessionLaunchLocking: Sendable {
    func withLock<T>(_ operation: () throws -> T) throws -> T
}

// MARK: - AntigravityCLISession

/// Manages a bounded background ``agy`` process whose embedded localhost server
/// provides the same ``GetUserStatus`` endpoint as the desktop Antigravity app's
/// ``language_server``. The CLI is kept alive in a PTY so its daemon stays bound
/// to a local port - this lets CodexBar read Claude + Gemini quotas even when
/// the desktop Antigravity app is closed.
///
/// The session intentionally does not scrape TUI output. It only launches and
/// keeps the process reachable for HTTPS probing, drains discarded PTY output so
/// the CLI cannot block on a full terminal buffer, and bounds the warm lifetime
/// with an idle timer so CodexBar does not run an IDE backend forever.
actor AntigravityCLISession {
    static let shared = AntigravityCLISession()
    private static let log = CodexBarLog.logger(LogCategories.antigravity)

    enum ResetCause: Int {
        case deferred
        case oneShotCLI
        case unhealthy
        case authentication

        var message: String {
            switch self {
            case .deferred: "deferred reset"
            case .oneShotCLI: "one-shot CLI fetch"
            case .unhealthy: "unhealthy CLI HTTPS session"
            case .authentication: "authentication required"
            }
        }
    }

    private struct LaunchOutcome {
        let pid: pid_t
        let rejectedProcess: (any AntigravityCLIProcessHandle)?
        let rejectionMessage: String?
        let holdsLaunchReservation: Bool
    }

    struct Dependencies {
        var launcher: any AntigravityCLIProcessLaunching
        var identityProvider: any AntigravityCLIProcessIdentityProviding
        var recordStore: any AntigravityCLISessionRecordStoring
        var launchLock: any AntigravityCLISessionLaunchLocking
        var beginAppShutdownTrackedLaunch: @Sendable () -> Bool
        var endAppShutdownTrackedLaunch: @Sendable () -> Void
        var registerForAppShutdown: @Sendable (pid_t, String) -> Bool
        var updateAppShutdownProcessGroup: @Sendable (pid_t, pid_t?) -> Void
        var unregisterForAppShutdown: @Sendable (pid_t) -> Void
        var descendantPIDs: @Sendable (pid_t) -> [pid_t]
        var terminateProcessTree: @Sendable (pid_t, pid_t?, Int32, [pid_t]) -> Void
        var currentProcessID: @Sendable () -> pid_t
        var now: @Sendable () -> Date
        var sleep: @Sendable (UInt64) async throws -> Void
        var idleWindow: TimeInterval
        var failureRelaunchThreshold: Int
        var terminationGracePeriod: TimeInterval

        static func live() -> Self {
            Self(
                launcher: AntigravityPTYProcessLauncher(),
                identityProvider: AntigravityProcessIdentityProvider(),
                recordStore: AntigravityFileCLISessionRecordStore(),
                launchLock: AntigravityFileCLISessionLaunchLock(),
                beginAppShutdownTrackedLaunch: {
                    TTYCommandRunner.beginActiveProcessLaunchForAppShutdown()
                },
                endAppShutdownTrackedLaunch: {
                    TTYCommandRunner.endActiveProcessLaunchForAppShutdown()
                },
                registerForAppShutdown: { pid, binary in
                    TTYCommandRunner.registerActiveProcessForAppShutdown(pid: pid, binary: binary)
                },
                updateAppShutdownProcessGroup: { pid, group in
                    TTYCommandRunner.updateActiveProcessGroupForAppShutdown(pid: pid, processGroup: group)
                },
                unregisterForAppShutdown: { pid in
                    TTYCommandRunner.unregisterActiveProcessForAppShutdown(pid: pid)
                },
                descendantPIDs: { pid in
                    TTYProcessTreeTerminator.descendantPIDs(of: pid)
                },
                terminateProcessTree: { pid, group, signal, knownDescendants in
                    TTYProcessTreeTerminator.terminateProcessTree(
                        rootPID: pid,
                        processGroup: group,
                        signal: signal,
                        knownDescendants: knownDescendants)
                },
                currentProcessID: getpid,
                now: Date.init,
                sleep: { nanoseconds in
                    try await Task.sleep(nanoseconds: nanoseconds)
                },
                idleWindow: 180,
                failureRelaunchThreshold: 2,
                terminationGracePeriod: 1)
        }
    }

    // MARK: State

    private let dependencies: Dependencies
    private var process: (any AntigravityCLIProcessHandle)?
    private var binaryPath: String?
    private var sessionIdleWindow: TimeInterval
    private var activeProbeCount = 0
    private var activeSessionProbeCount = 0
    private var resetRequestedWhenIdle = false
    private var hardResetRequestedWhenIdle = false
    private var pendingResetCause: ResetCause?
    private var idleTask: Task<Void, Never>?
    private var sessionGeneration: UInt64 = 0
    private var consecutiveProbeFailures = 0
    private var persistedProcessIdentity: AntigravityCLIProcessIdentity?
    private var recentOutput = Data()
    private var authenticationPromptObserved = false
    private var lastStopReason: String?
    private var lifecycleOperationInProgress = false
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    private var exclusiveProbeWaiters: [CheckedContinuation<Void, Never>] = []

    init(dependencies: Dependencies = .live()) {
        self.dependencies = dependencies
        self.sessionIdleWindow = dependencies.idleWindow
    }

    /// The pid of the running ``agy`` process, exposed so callers can discover
    /// its listening ports via `lsof`.
    var pid: pid_t? {
        guard let proc = self.process, proc.isRunning else { return nil }
        return proc.pid
    }

    /// Whether the managed process is alive and matches ``binaryPath``.
    var isRunning: Bool {
        guard let proc = self.process, proc.isRunning, self.binaryPath != nil else { return false }
        return true
    }

    var failureCountForTesting: Int {
        self.consecutiveProbeFailures
    }

    var idleWindowForTesting: TimeInterval {
        self.sessionIdleWindow
    }

    var activeProbeCountForTesting: Int {
        self.activeProbeCount
    }

    var lastStopReasonForTesting: String? {
        self.lastStopReason
    }

    // MARK: Lifecycle

    /// Mark a probe as active and ensure a warm ``agy`` is running on the given binary path.
    ///
    /// Callers must balance this with ``finishProbe(success:resetAfterFetch:)`` so
    /// idle/reset cleanup cannot kill the process while its ports are being probed.
    /// If previous probes repeatedly failed while the process stayed alive, this
    /// force-relaunches instead of reusing a wedged HTTPS server forever.
    func beginProbe(binary: String, idleWindow: TimeInterval? = nil) async throws -> pid_t {
        self.activeProbeCount += 1
        if let idleWindow, idleWindow > 0 {
            self.sessionIdleWindow = max(self.dependencies.idleWindow, idleWindow)
        }
        self.cancelIdleTimer()
        do {
            return try await self.withLifecycleOperation {
                let pid = try await self.ensureStartedLocked(binary: binary)
                self.activeSessionProbeCount += 1
                return pid
            }
        } catch {
            self.activeProbeCount = max(0, self.activeProbeCount - 1)
            self.notifyExclusiveProbeWaitersIfNeeded()
            if self.activeProbeCount == 0, self.resetRequestedWhenIdle {
                await self.withLifecycleOperation {
                    guard self.activeProbeCount == 0 else {
                        self.resetRequestedWhenIdle = true
                        return
                    }
                    let forceTerminate = self.hardResetRequestedWhenIdle || self.consecutiveProbeFailures > 0
                    self.resetRequestedWhenIdle = false
                    self.hardResetRequestedWhenIdle = false
                    await self.stopCurrentSessionLocked(
                        reason: "deferred reset after failed begin",
                        clearRecord: true,
                        graceful: !forceTerminate)
                }
            }
            throw error
        }
    }

    /// Record probe completion and either keep the session warm for the bounded
    /// idle window or tear it down immediately for one-shot CLI invocations.
    func finishProbe(success: Bool, resetAfterFetch: Bool, forceTerminate: Bool = false) async {
        if success {
            self.consecutiveProbeFailures = 0
        } else {
            self.consecutiveProbeFailures += 1
        }

        self.activeProbeCount = max(0, self.activeProbeCount - 1)
        self.activeSessionProbeCount = max(0, self.activeSessionProbeCount - 1)
        self.notifyExclusiveProbeWaitersIfNeeded()
        let shouldForceStopUnhealthy = !success &&
            self.consecutiveProbeFailures >= max(1, self.dependencies.failureRelaunchThreshold)
        let shouldReset = forceTerminate || resetAfterFetch || self.resetRequestedWhenIdle || shouldForceStopUnhealthy
        let currentResetCause = Self.resetCause(
            authenticationRequired: forceTerminate,
            resetAfterFetch: resetAfterFetch,
            shouldForceStopUnhealthy: shouldForceStopUnhealthy)

        guard self.activeProbeCount == 0 else {
            if shouldReset {
                self.resetRequestedWhenIdle = true
                self.pendingResetCause = Self.strongestResetCause(self.pendingResetCause, currentResetCause)
            }
            if shouldReset, !success || forceTerminate {
                self.hardResetRequestedWhenIdle = true
            }
            return
        }

        if shouldReset {
            let shouldForceTerminate = !success || forceTerminate || self.hardResetRequestedWhenIdle
            let resetCause = Self.strongestResetCause(self.pendingResetCause, currentResetCause)
            await self.withLifecycleOperation {
                guard self.activeProbeCount == 0 else {
                    self.resetRequestedWhenIdle = true
                    self.pendingResetCause = Self.strongestResetCause(self.pendingResetCause, resetCause)
                    if shouldForceTerminate {
                        self.hardResetRequestedWhenIdle = true
                    }
                    return
                }
                self.resetRequestedWhenIdle = false
                self.hardResetRequestedWhenIdle = false
                self.pendingResetCause = nil
                await self.stopCurrentSessionLocked(
                    reason: resetCause.message,
                    clearRecord: true,
                    graceful: !shouldForceTerminate)
            }
        } else {
            self.armIdleTimer()
        }
    }

    static func resetCause(
        authenticationRequired: Bool,
        resetAfterFetch: Bool,
        shouldForceStopUnhealthy: Bool) -> ResetCause
    {
        if authenticationRequired {
            .authentication
        } else if shouldForceStopUnhealthy {
            .unhealthy
        } else if resetAfterFetch {
            .oneShotCLI
        } else {
            .deferred
        }
    }

    static func strongestResetCause(_ existing: ResetCause?, _ incoming: ResetCause) -> ResetCause {
        guard let existing else { return incoming }
        return existing.rawValue >= incoming.rawValue ? existing : incoming
    }

    /// Ensure a warm ``agy`` is running on the given binary path.
    ///
    /// - If the process is already alive with the same binary, this returns immediately.
    /// - If the process died, the binary changed, or repeated probes failed, it tears down the old one first.
    /// - Returns the process identifier for port discovery.
    func ensureStarted(binary: String) async throws -> pid_t {
        try await self.withLifecycleOperation {
            try await self.ensureStartedLocked(binary: binary)
        }
    }

    /// Request teardown. If a probe is in flight, cleanup is deferred until the
    /// matching ``finishProbe(success:resetAfterFetch:)`` call.
    func reset() async {
        self.cancelIdleTimer()
        guard self.activeProbeCount == 0 else {
            self.resetRequestedWhenIdle = true
            return
        }
        await self.withLifecycleOperation {
            guard self.activeProbeCount == 0 else {
                self.resetRequestedWhenIdle = true
                return
            }
            self.resetRequestedWhenIdle = false
            let forceTerminate = self.hardResetRequestedWhenIdle || self.consecutiveProbeFailures > 0
            self.hardResetRequestedWhenIdle = false
            await self.stopCurrentSessionLocked(
                reason: "manual reset",
                clearRecord: true,
                graceful: !forceTerminate)
        }
    }

    /// Drain PTY output into one rolling buffer shared by concurrent probes.
    func drainOutput() -> Data {
        var searchableOutput = self.recentOutput
        if let output = self.process?.drainOutput(), !output.isEmpty {
            searchableOutput.append(output)
            self.recentOutput = Data(searchableOutput.suffix(4096))
        }

        if !self.authenticationPromptObserved,
           AntigravityCLIAuthenticationPrompt.contains(searchableOutput)
        {
            self.authenticationPromptObserved = true
        }
        if self.authenticationPromptObserved,
           !AntigravityCLIAuthenticationPrompt.contains(searchableOutput)
        {
            searchableOutput.append(AntigravityCLIAuthenticationPrompt.evidence)
        }
        return searchableOutput
    }

    // MARK: Errors

    enum SessionError: LocalizedError {
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case let .launchFailed(msg): "Failed to launch Antigravity CLI session: \(msg)"
            }
        }
    }

    // MARK: Private

    private func withLifecycleOperation<T>(_ operation: () async throws -> T) async throws -> T {
        await self.acquireLifecycleOperation()
        defer { self.releaseLifecycleOperation() }
        return try await operation()
    }

    private func withLifecycleOperation(_ operation: () async -> Void) async {
        await self.acquireLifecycleOperation()
        defer { self.releaseLifecycleOperation() }
        await operation()
    }

    private func acquireLifecycleOperation() async {
        guard self.lifecycleOperationInProgress else {
            self.lifecycleOperationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            self.lifecycleWaiters.append(continuation)
        }
    }

    private func releaseLifecycleOperation() {
        guard !self.lifecycleWaiters.isEmpty else {
            self.lifecycleOperationInProgress = false
            return
        }
        let next = self.lifecycleWaiters.removeFirst()
        next.resume()
    }

    private func waitForExclusiveProbeIfNeeded() async {
        while self.activeSessionProbeCount > 0 {
            await withCheckedContinuation { continuation in
                self.exclusiveProbeWaiters.append(continuation)
            }
        }
    }

    private func notifyExclusiveProbeWaitersIfNeeded() {
        guard self.activeSessionProbeCount == 0, !self.exclusiveProbeWaiters.isEmpty else { return }
        let waiters = self.exclusiveProbeWaiters
        self.exclusiveProbeWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func ensureStartedLocked(binary: String) async throws -> pid_t {
        while true {
            if let proc = self.process,
               proc.isRunning,
               self.binaryPath == binary,
               !self.resetRequestedWhenIdle,
               !self.hardResetRequestedWhenIdle,
               self.consecutiveProbeFailures < max(1, self.dependencies.failureRelaunchThreshold)
            {
                try? self.dependencies.launchLock.withLock {
                    self.reapRecordedSessionsIfNeeded()
                }
                self.persistCurrentRecordIfNeeded(proc, binary: binary)
                Self.log.debug("Antigravity CLI session reused", metadata: ["pid": "\(proc.pid)"])
                return proc.pid
            }

            if self.process != nil {
                if self.activeSessionProbeCount > 0 {
                    await self.waitForExclusiveProbeIfNeeded()
                    continue
                }

                let reason = self.consecutiveProbeFailures >= max(1, self.dependencies.failureRelaunchThreshold)
                    ? "relaunching unhealthy session"
                    : "replacing stale session"
                let forceTerminate = self.hardResetRequestedWhenIdle || self.consecutiveProbeFailures > 0
                self.resetRequestedWhenIdle = false
                self.hardResetRequestedWhenIdle = false
                await self.stopCurrentSessionLocked(
                    reason: reason,
                    clearRecord: true,
                    graceful: !forceTerminate)
            }

            let binaryName = URL(fileURLWithPath: binary).lastPathComponent
            let launch: (Bool) throws -> LaunchOutcome = { canPersistRecord in
                if canPersistRecord {
                    self.prepareRecordStoreForLaunch()
                }
                guard self.dependencies.beginAppShutdownTrackedLaunch() else {
                    throw SessionError.launchFailed("App shutdown in progress")
                }
                let launched: any AntigravityCLIProcessHandle
                do {
                    launched = try self.dependencies.launcher.launch(binary: binary)
                } catch {
                    self.dependencies.endAppShutdownTrackedLaunch()
                    throw error
                }
                let launchedPID = launched.pid
                guard self.dependencies.registerForAppShutdown(launchedPID, binaryName) else {
                    return LaunchOutcome(
                        pid: launchedPID,
                        rejectedProcess: launched,
                        rejectionMessage: "App shutdown in progress",
                        holdsLaunchReservation: true)
                }

                let processGroup = launched.processGroup ?? launched.assignProcessGroup()
                self.dependencies.updateAppShutdownProcessGroup(launchedPID, processGroup)

                self.process = launched
                self.binaryPath = binary
                self.recentOutput.removeAll(keepingCapacity: true)
                self.authenticationPromptObserved = false
                self.consecutiveProbeFailures = 0
                self.sessionGeneration &+= 1
                if canPersistRecord {
                    _ = self.persistRecord(pid: launchedPID, binary: binary, processGroup: processGroup)
                } else {
                    self.persistedProcessIdentity = nil
                }
                self.dependencies.endAppShutdownTrackedLaunch()
                return LaunchOutcome(
                    pid: launchedPID,
                    rejectedProcess: nil,
                    rejectionMessage: nil,
                    holdsLaunchReservation: false)
            }

            var lockedLaunch: Result<LaunchOutcome, Error>?
            var lockFailure: Error?
            do {
                try self.dependencies.launchLock.withLock {
                    lockedLaunch = Result { try launch(true) }
                }
            } catch {
                lockFailure = error
            }

            let outcome: LaunchOutcome
            if let lockFailure {
                Self.log.warning(
                    "Antigravity CLI session coordination unavailable",
                    metadata: ["error": lockFailure.localizedDescription])
                outcome = try launch(false)
            } else if let lockedLaunch {
                outcome = try lockedLaunch.get()
            } else {
                throw SessionError.launchFailed("CLI session launch did not complete")
            }
            if let rejectedProcess = outcome.rejectedProcess {
                await self.terminateLaunchedProcess(rejectedProcess, graceful: false)
                if outcome.holdsLaunchReservation {
                    self.dependencies.endAppShutdownTrackedLaunch()
                }
                throw SessionError.launchFailed(outcome.rejectionMessage ?? "App shutdown in progress")
            }

            Self.log.debug(
                "Antigravity CLI session started",
                metadata: [
                    "binary": binaryName,
                    "pid": "\(outcome.pid)",
                ])
            return outcome.pid
        }
    }

    private func prepareRecordStoreForLaunch() {
        guard self.process == nil || self.persistedProcessIdentity == nil else { return }
        self.reapRecordedSessionsIfNeeded()
    }

    private func persistCurrentRecordIfNeeded(_ proc: any AntigravityCLIProcessHandle, binary: String) {
        guard self.persistedProcessIdentity == nil else { return }
        try? self.dependencies.launchLock.withLock {
            self.prepareRecordStoreForLaunch()
            _ = self.persistRecord(pid: proc.pid, binary: binary, processGroup: proc.processGroup)
        }
    }

    private func cancelIdleTimer() {
        self.idleTask?.cancel()
        self.idleTask = nil
    }

    private func armIdleTimer() {
        guard self.process != nil, self.sessionIdleWindow > 0 else { return }
        self.cancelIdleTimer()
        let generation = self.sessionGeneration
        let nanoseconds = Self.nanoseconds(from: self.sessionIdleWindow)
        let sleep = self.dependencies.sleep
        self.idleTask = Task { [weak self] in
            do {
                try await sleep(nanoseconds)
                await self?.stopIfIdle(generation: generation)
            } catch {
                // Cancellation is the normal path when a refresh reuses the warm session.
            }
        }
    }

    private func stopIfIdle(generation: UInt64) async {
        await self.withLifecycleOperation {
            guard generation == self.sessionGeneration else { return }
            guard self.activeProbeCount == 0 else {
                self.armIdleTimer()
                return
            }
            let forceTerminate = self.hardResetRequestedWhenIdle || self.consecutiveProbeFailures > 0
            self.resetRequestedWhenIdle = false
            self.hardResetRequestedWhenIdle = false
            await self.stopCurrentSessionLocked(
                reason: "idle timeout",
                clearRecord: true,
                graceful: !forceTerminate)
        }
    }

    private func stopCurrentSessionLocked(reason: String, clearRecord: Bool, graceful: Bool = true) async {
        self.cancelIdleTimer()
        let effectiveReason = self.pendingResetCause?.message ?? reason
        self.pendingResetCause = nil
        self.lastStopReason = effectiveReason
        guard let proc = self.process else {
            if clearRecord {
                try? self.dependencies.launchLock.withLock {
                    self.reapRecordedSessionsIfNeeded()
                }
            }
            self.sessionIdleWindow = self.dependencies.idleWindow
            self.recentOutput.removeAll(keepingCapacity: true)
            self.authenticationPromptObserved = false
            return
        }

        let pid = proc.pid
        let identity = self.persistedProcessIdentity
        Self.log.debug("Antigravity CLI session stopping", metadata: ["pid": "\(pid)", "reason": "\(effectiveReason)"])

        self.process = nil
        self.binaryPath = nil
        self.persistedProcessIdentity = nil
        self.sessionIdleWindow = self.dependencies.idleWindow
        self.recentOutput.removeAll(keepingCapacity: true)
        self.authenticationPromptObserved = false
        self.sessionGeneration &+= 1

        await self.terminateLaunchedProcess(proc, graceful: graceful)
        self.dependencies.unregisterForAppShutdown(pid)
        if clearRecord {
            self.removeRecordIfMatches(pid: pid, identity: identity)
        }
    }

    private func terminateLaunchedProcess(
        _ proc: any AntigravityCLIProcessHandle,
        graceful: Bool = true) async
    {
        if graceful {
            try? proc.sendExit()
        }
        proc.closePTY()

        let descendants = proc.descendantPIDs()
        if proc.isRunning {
            proc.terminateRoot()
        }
        proc.terminateTree(signal: SIGTERM, knownDescendants: descendants)

        let gracePeriod = self.dependencies.terminationGracePeriod
        if gracePeriod > 0 {
            let deadline = self.dependencies.now().addingTimeInterval(gracePeriod)
            while proc.isRunning, self.dependencies.now() < deadline {
                try? await self.dependencies.sleep(100_000_000)
            }
        }

        if proc.isRunning {
            proc.terminateTree(signal: SIGKILL, knownDescendants: descendants)
            await self.waitUntilProcessExits(proc, timeout: 1)
        } else {
            proc.killDescendants(descendants)
        }
    }

    private func waitUntilProcessExits(_ proc: any AntigravityCLIProcessHandle, timeout: TimeInterval) async {
        let deadline = self.dependencies.now().addingTimeInterval(timeout)
        while proc.isRunning, self.dependencies.now() < deadline {
            try? await self.dependencies.sleep(50_000_000)
        }
        _ = proc.isRunning
    }

    @discardableResult
    private func persistRecord(pid: pid_t, binary: String, processGroup: pid_t?) -> Bool {
        guard let identity = self.dependencies.identityProvider.identity(for: pid) else {
            self.persistedProcessIdentity = nil
            return false
        }
        let ownerPID = self.dependencies.currentProcessID()
        let ownerIdentity = self.dependencies.identityProvider.identity(for: ownerPID)
        let record = AntigravityCLISessionRecord(
            pid: pid,
            requestedBinaryPath: binary,
            executablePath: identity.executablePath,
            startEpoch: identity.startEpoch,
            processGroup: processGroup,
            ownerPID: ownerPID,
            ownerExecutablePath: ownerIdentity?.executablePath,
            ownerStartEpoch: ownerIdentity?.startEpoch)
        do {
            try self.dependencies.recordStore.save(record)
            self.persistedProcessIdentity = identity
            return true
        } catch {
            self.persistedProcessIdentity = nil
            return false
        }
    }

    private func reapRecordedSessionsIfNeeded() {
        guard let records = try? self.dependencies.recordStore.load() else { return }
        for record in records {
            guard let liveIdentity = self.dependencies.identityProvider.identity(for: record.pid),
                  liveIdentity.executablePath == record.executablePath,
                  abs(liveIdentity.startEpoch - record.startEpoch) < 0.001
            else {
                try? self.dependencies.recordStore.remove(record)
                continue
            }
            if let proc = self.process, proc.pid == record.pid {
                self.persistedProcessIdentity = liveIdentity
                continue
            }
            if let ownerPID = record.ownerPID,
               ownerPID != self.dependencies.currentProcessID(),
               let ownerExecutablePath = record.ownerExecutablePath,
               let ownerStartEpoch = record.ownerStartEpoch,
               let liveOwnerIdentity = self.dependencies.identityProvider.identity(for: ownerPID),
               liveOwnerIdentity.executablePath == ownerExecutablePath,
               abs(liveOwnerIdentity.startEpoch - ownerStartEpoch) < 0.001
            {
                continue
            }

            let knownDescendants = self.dependencies.descendantPIDs(record.pid)
            Self.log.debug("Reaping stale Antigravity CLI session", metadata: ["pid": "\(record.pid)"])
            self.dependencies.terminateProcessTree(record.pid, record.processGroup, SIGTERM, knownDescendants)
            self.dependencies.terminateProcessTree(record.pid, record.processGroup, SIGKILL, knownDescendants)
            try? self.dependencies.recordStore.remove(record)
        }
    }

    private func removeRecordIfMatches(pid: pid_t, identity: AntigravityCLIProcessIdentity?) {
        try? self.dependencies.launchLock.withLock {
            guard let identity, let records = try? self.dependencies.recordStore.load() else { return }
            for record in records
                where record.pid == pid &&
                record.executablePath == identity.executablePath &&
                abs(record.startEpoch - identity.startEpoch) < 0.001
            {
                try? self.dependencies.recordStore.remove(record)
            }
        }
    }

    private static func nanoseconds(from interval: TimeInterval) -> UInt64 {
        guard interval > 0 else { return 0 }
        guard interval.isFinite else { return UInt64.max }
        let nanoseconds = interval * 1_000_000_000
        guard nanoseconds < TimeInterval(UInt64.max) else { return UInt64.max }
        return UInt64(nanoseconds)
    }
}

// MARK: - Production Process Implementation

struct AntigravityPTYProcessLauncher: AntigravityCLIProcessLaunching {
    static func defaultSignalsForSpawn() -> sigset_t {
        var signals = sigset_t()
        sigemptyset(&signals)
        sigaddset(&signals, SIGINT)
        sigaddset(&signals, SIGTERM)
        sigaddset(&signals, SIGHUP)
        return signals
    }

    static func spawnWithTextBusyRetry(
        maxAttempts: Int = 3,
        retryDelay: TimeInterval = 0.01,
        spawn: () -> Int32) -> Int32
    {
        var result = spawn()
        guard maxAttempts > 1 else { return result }

        for _ in 1..<maxAttempts where result == ETXTBSY {
            if retryDelay > 0 {
                Thread.sleep(forTimeInterval: retryDelay)
            }
            result = spawn()
        }
        return result
    }

    func launch(binary: String) throws -> any AntigravityCLIProcessHandle {
        try self.launch(binary: binary, arguments: [])
    }

    func launch(binary: String, arguments: [String]) throws -> any AntigravityCLIProcessHandle {
        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var win = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &win) == 0 else {
            throw AntigravityCLISession.SessionError.launchFailed("openpty failed")
        }
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        let primaryHandle = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondaryHandle = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)

        #if canImport(Darwin)
        var fileActions: posix_spawn_file_actions_t?
        #else
        var fileActions = posix_spawn_file_actions_t()
        #endif
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            try? primaryHandle.close()
            try? secondaryHandle.close()
            throw AntigravityCLISession.SessionError.launchFailed("posix_spawn_file_actions_init failed")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, 0)
        posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, 1)
        posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, 2)
        posix_spawn_file_actions_addclose(&fileActions, primaryFD)
        posix_spawn_file_actions_addclose(&fileActions, secondaryFD)

        let homeDirectory = NSHomeDirectory()
        _ = homeDirectory.withCString { path in
            posix_spawn_file_actions_addchdir_np(&fileActions, path)
        }
        #if canImport(Glibc) || canImport(Musl)
        do {
            try PosixSpawnFileActionsCloseFrom.addCloseFrom(&fileActions, startingAt: 3)
        } catch {
            try? primaryHandle.close()
            try? secondaryHandle.close()
            throw AntigravityCLISession.SessionError.launchFailed(error.localizedDescription)
        }
        #endif

        #if canImport(Darwin)
        var attr: posix_spawnattr_t?
        #else
        var attr = posix_spawnattr_t()
        #endif
        guard posix_spawnattr_init(&attr) == 0 else {
            try? primaryHandle.close()
            try? secondaryHandle.close()
            throw AntigravityCLISession.SessionError.launchFailed("posix_spawnattr_init failed")
        }
        defer { posix_spawnattr_destroy(&attr) }
        var defaultSignals = Self.defaultSignalsForSpawn()
        posix_spawnattr_setsigdefault(&attr, &defaultSignals)
        #if canImport(Darwin)
        let spawnFlags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        #else
        let spawnFlags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF
        #endif
        posix_spawnattr_setflags(&attr, Int16(spawnFlags))
        posix_spawnattr_setpgroup(&attr, 0)

        var env = TTYCommandRunner.enrichedEnvironment()
        env["PWD"] = NSHomeDirectory()
        env["TERM"] = "xterm-256color"

        var cArgs = ([binary] + arguments).map { strdup($0) as UnsafeMutablePointer<CChar>? }
        cArgs.append(nil)
        defer {
            for arg in cArgs {
                if let arg {
                    free(arg)
                }
            }
        }

        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { key, value in
            strdup("\(key)=\(value)")
        }
        cEnv.append(nil)
        defer {
            for entry in cEnv {
                if let entry {
                    free(entry)
                }
            }
        }

        var pid: pid_t = 0
        let spawnResult = Self.spawnWithTextBusyRetry {
            binary.withCString { execPath in
                posix_spawn(&pid, execPath, &fileActions, &attr, cArgs, cEnv)
            }
        }
        guard spawnResult == 0 else {
            try? primaryHandle.close()
            try? secondaryHandle.close()
            throw AntigravityCLISession.SessionError.launchFailed(String(cString: strerror(spawnResult)))
        }

        return AntigravitySpawnedPTYProcessHandle(
            pid: pid,
            processGroup: pid,
            primaryFD: primaryFD,
            primaryHandle: primaryHandle,
            secondaryHandle: secondaryHandle)
    }
}

final class AntigravitySpawnedPTYProcessHandle: AntigravityCLIProcessHandle, @unchecked Sendable {
    private let lock = NSLock()
    private let processPID: pid_t
    private let processGroupID: pid_t
    private let primaryFD: Int32
    private let primaryHandle: FileHandle
    private let secondaryHandle: FileHandle
    private var reaped = false

    init(
        pid: pid_t,
        processGroup: pid_t,
        primaryFD: Int32,
        primaryHandle: FileHandle,
        secondaryHandle: FileHandle)
    {
        self.processPID = pid
        self.processGroupID = processGroup
        self.primaryFD = primaryFD
        self.primaryHandle = primaryHandle
        self.secondaryHandle = secondaryHandle
    }

    var pid: pid_t {
        self.processPID
    }

    var isRunning: Bool {
        self.lock.lock()
        if self.reaped {
            self.lock.unlock()
            return false
        }
        self.lock.unlock()

        var status: Int32 = 0
        let result = waitpid(self.processPID, &status, WNOHANG)

        self.lock.lock()
        defer { self.lock.unlock() }
        switch result {
        case 0:
            return true
        case self.processPID:
            self.reaped = true
            return false
        case -1 where errno == ECHILD:
            self.reaped = true
            return false
        default:
            return kill(self.processPID, 0) == 0 || errno == EPERM
        }
    }

    var processGroup: pid_t? {
        self.processGroupID
    }

    func assignProcessGroup() -> pid_t? {
        self.processGroupID
    }

    func sendExit() throws {
        try self.writeAllToPrimary(Data("/exit\r".utf8))
    }

    func closePTY() {
        try? self.primaryHandle.close()
        try? self.secondaryHandle.close()
    }

    func terminateRoot() {
        kill(self.processPID, SIGTERM)
    }

    func killRoot() {
        kill(self.processPID, SIGKILL)
    }

    func descendantPIDs() -> [pid_t] {
        TTYProcessTreeTerminator.descendantPIDs(of: self.processPID)
    }

    func terminateTree(signal: Int32, knownDescendants: [pid_t]) {
        TTYProcessTreeTerminator.terminateProcessTree(
            rootPID: self.processPID,
            processGroup: self.processGroupID,
            signal: signal,
            knownDescendants: knownDescendants)
    }

    func killDescendants(_ descendants: [pid_t]) {
        for pid in descendants where pid > 0 {
            kill(pid, SIGKILL)
        }
    }

    func drainOutput() -> Data {
        var tmp = [UInt8](repeating: 0, count: 8192)
        var output: [UInt8] = []
        for _ in 0..<64 {
            let n = read(self.primaryFD, &tmp, tmp.count)
            if n > 0 {
                output.append(contentsOf: tmp.prefix(n))
                continue
            }
            break
        }
        return Data(output)
    }

    private func writeAllToPrimary(_ data: Data) throws {
        data.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress else { return }
            var offset = 0
            var retries = 0
            while offset < rawBytes.count {
                let written = write(self.primaryFD, baseAddress.advanced(by: offset), rawBytes.count - offset)
                if written > 0 {
                    offset += written
                    retries = 0
                    continue
                }
                if written == 0 { break }

                let err = errno
                if err == EINTR || err == EAGAIN || err == EWOULDBLOCK {
                    retries += 1
                    if retries > 200 { return }
                    usleep(5000)
                    continue
                }
                return
            }
        }
    }
}

// MARK: - Production Stale Session Identity + Storage

struct AntigravityProcessIdentityProvider: AntigravityCLIProcessIdentityProviding {
    static var currentUserID: UInt32 {
        UInt32(getuid())
    }

    func ownerUserID(for pid: pid_t) -> UInt32? {
        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.stride))
        guard size == Int32(MemoryLayout<proc_bsdinfo>.stride) else { return nil }
        return info.pbi_uid
        #else
        guard let status = try? String(contentsOfFile: "/proc/\(pid)/status", encoding: .utf8),
              let uidLine = status.split(separator: "\n").first(where: { $0.hasPrefix("Uid:") }),
              let owner = uidLine.split(whereSeparator: \.isWhitespace).dropFirst().first,
              let userID = UInt32(owner)
        else {
            return nil
        }
        return userID
        #endif
    }

    func identity(for pid: pid_t) -> AntigravityCLIProcessIdentity? {
        #if canImport(Darwin)
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        let executablePath = pathBuffer.withUnsafeBufferPointer { buffer -> String? in
            let rawBytes = UnsafeRawBufferPointer(start: buffer.baseAddress, count: Int(pathLength))
            return String(bytes: rawBytes.prefix { $0 != 0 }, encoding: .utf8)
        }
        guard let executablePath, !executablePath.isEmpty else { return nil }

        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.stride))
        guard size == Int32(MemoryLayout<proc_bsdinfo>.stride) else { return nil }
        let startEpoch = TimeInterval(info.pbi_start_tvsec) + (TimeInterval(info.pbi_start_tvusec) / 1_000_000)
        return AntigravityCLIProcessIdentity(executablePath: executablePath, startEpoch: startEpoch)
        #else
        let procDirectory = "/proc/\(pid)"
        guard let executablePath = try? FileManager.default.destinationOfSymbolicLink(
            atPath: "\(procDirectory)/exe"),
            let stat = try? String(contentsOfFile: "\(procDirectory)/stat", encoding: .utf8),
            let closeParen = stat.lastIndex(of: ")")
        else {
            return nil
        }
        let fields = stat[stat.index(after: closeParen)...].split(whereSeparator: \.isWhitespace)
        let clockTicksPerSecond = sysconf(Int32(_SC_CLK_TCK))
        let systemStat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8)
        let bootEpoch = systemStat?
            .split(separator: "\n")
            .first { $0.hasPrefix("btime ") }?
            .split(whereSeparator: \.isWhitespace)
            .dropFirst()
            .first
            .flatMap { TimeInterval($0) }
        guard fields.count > 19,
              let startTicks = TimeInterval(fields[19]),
              clockTicksPerSecond > 0,
              let bootEpoch
        else {
            return nil
        }
        let startEpoch = bootEpoch + (startTicks / TimeInterval(clockTicksPerSecond))
        return AntigravityCLIProcessIdentity(executablePath: executablePath, startEpoch: startEpoch)
        #endif
    }
}

final class AntigravityFileCLISessionRecordStore: AntigravityCLISessionRecordStoring, @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codexbar", isDirectory: true)
            .appendingPathComponent("antigravity", isDirectory: true)
            .appendingPathComponent("agy-session.json"),
        fileManager: FileManager = .default)
    {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() throws -> [AntigravityCLISessionRecord] {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return [] }
        let data = try Data(contentsOf: self.fileURL)
        let decoder = JSONDecoder()
        if let records = try? decoder.decode([AntigravityCLISessionRecord].self, from: data) {
            return records
        }
        return try [decoder.decode(AntigravityCLISessionRecord.self, from: data)]
    }

    func save(_ record: AntigravityCLISessionRecord) throws {
        var records = (try? self.load()) ?? []
        records.removeAll { Self.sameOwner($0, record) }
        records.append(record)
        try self.write(records)
    }

    func remove(_ record: AntigravityCLISessionRecord) throws {
        var records = try self.load()
        records.removeAll {
            $0.pid == record.pid &&
                $0.executablePath == record.executablePath &&
                abs($0.startEpoch - record.startEpoch) < 0.001
        }
        if records.isEmpty {
            guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return }
            try self.fileManager.removeItem(at: self.fileURL)
        } else {
            try self.write(records)
        }
    }

    private func write(_ records: [AntigravityCLISessionRecord]) throws {
        let directory = self.fileURL.deletingLastPathComponent()
        try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: self.fileURL, options: [.atomic])
    }

    private static func sameOwner(
        _ lhs: AntigravityCLISessionRecord,
        _ rhs: AntigravityCLISessionRecord) -> Bool
    {
        if let lhsOwnerPID = lhs.ownerPID,
           let rhsOwnerPID = rhs.ownerPID,
           let lhsOwnerPath = lhs.ownerExecutablePath,
           let rhsOwnerPath = rhs.ownerExecutablePath,
           let lhsOwnerStart = lhs.ownerStartEpoch,
           let rhsOwnerStart = rhs.ownerStartEpoch
        {
            return lhsOwnerPID == rhsOwnerPID &&
                lhsOwnerPath == rhsOwnerPath &&
                abs(lhsOwnerStart - rhsOwnerStart) < 0.001
        }
        return lhs.pid == rhs.pid &&
            lhs.executablePath == rhs.executablePath &&
            abs(lhs.startEpoch - rhs.startEpoch) < 0.001
    }
}

final class AntigravityFileCLISessionLaunchLock: AntigravityCLISessionLaunchLocking, @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codexbar", isDirectory: true)
            .appendingPathComponent("antigravity", isDirectory: true)
            .appendingPathComponent("agy-session.lock"),
        fileManager: FileManager = .default)
    {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func withLock<T>(_ operation: () throws -> T) throws -> T {
        let directory = self.fileURL.deletingLastPathComponent()
        try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(self.fileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }

        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return try operation()
    }
}
