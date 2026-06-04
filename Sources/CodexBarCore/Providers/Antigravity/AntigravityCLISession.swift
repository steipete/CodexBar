#if canImport(Darwin)
import Darwin
#else
import Glibc
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
    func drainOutput()
}

protocol AntigravityCLIProcessLaunching: Sendable {
    func launch(binary: String) throws -> any AntigravityCLIProcessHandle
}

struct AntigravityCLIProcessIdentity: Equatable, Sendable {
    let executablePath: String
    let startEpoch: TimeInterval
}

protocol AntigravityCLIProcessIdentityProviding: Sendable {
    func identity(for pid: pid_t) -> AntigravityCLIProcessIdentity?
}

struct AntigravityCLISessionRecord: Codable, Equatable, Sendable {
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
    func load() throws -> AntigravityCLISessionRecord?
    func save(_ record: AntigravityCLISessionRecord) throws
    func remove() throws
}

// MARK: - AntigravityCLISession

/// Manages a bounded background ``agy`` process whose embedded localhost server
/// provides the same ``GetUserStatus`` endpoint as the desktop Antigravity app's
/// ``language_server``. The CLI is kept alive in a PTY so its daemon stays bound
/// to a local port — this lets CodexBar read Claude + Gemini quotas even when
/// the desktop Antigravity app is closed.
///
/// The session intentionally does not scrape TUI output. It only launches and
/// keeps the process reachable for HTTPS probing, drains discarded PTY output so
/// the CLI cannot block on a full terminal buffer, and bounds the warm lifetime
/// with an idle timer so CodexBar does not run an IDE backend forever.
actor AntigravityCLISession {
    static let shared = AntigravityCLISession()
    private static let log = CodexBarLog.logger(LogCategories.antigravity)

    struct Dependencies: Sendable {
        var launcher: any AntigravityCLIProcessLaunching
        var identityProvider: any AntigravityCLIProcessIdentityProviding
        var recordStore: any AntigravityCLISessionRecordStoring
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
                identityProvider: AntigravityDarwinProcessIdentityProvider(),
                recordStore: AntigravityFileCLISessionRecordStore(),
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
    private var activeProbeCount = 0
    private var activeSessionProbeCount = 0
    private var resetRequestedWhenIdle = false
    private var idleTask: Task<Void, Never>?
    private var sessionGeneration: UInt64 = 0
    private var consecutiveProbeFailures = 0
    private var persistedProcessIdentity: AntigravityCLIProcessIdentity?
    private var lifecycleOperationInProgress = false
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    private var exclusiveProbeWaiters: [CheckedContinuation<Void, Never>] = []

    init(dependencies: Dependencies = .live()) {
        self.dependencies = dependencies
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

    // MARK: Lifecycle

    /// Mark a probe as active and ensure a warm ``agy`` is running on the given binary path.
    ///
    /// Callers must balance this with ``finishProbe(success:resetAfterFetch:)`` so
    /// idle/reset cleanup cannot kill the process while its ports are being probed.
    /// If previous probes repeatedly failed while the process stayed alive, this
    /// force-relaunches instead of reusing a wedged HTTPS server forever.
    func beginProbe(binary: String) async throws -> pid_t {
        self.activeProbeCount += 1
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
                    await self.stopCurrentSessionLocked(reason: "deferred reset after failed begin", clearRecord: true)
                }
            }
            throw error
        }
    }

    /// Record probe completion and either keep the session warm for the bounded
    /// idle window or tear it down immediately for one-shot CLI invocations.
    func finishProbe(success: Bool, resetAfterFetch: Bool) async {
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
        let shouldReset = resetAfterFetch || self.resetRequestedWhenIdle || shouldForceStopUnhealthy

        guard self.activeProbeCount == 0 else {
            if shouldReset {
                self.resetRequestedWhenIdle = true
            }
            return
        }

        if shouldReset {
            let reason =
                if resetAfterFetch {
                    "one-shot CLI fetch"
                } else if shouldForceStopUnhealthy {
                    "unhealthy CLI HTTPS session"
                } else {
                    "deferred reset"
                }
            await self.withLifecycleOperation {
                guard self.activeProbeCount == 0 else {
                    self.resetRequestedWhenIdle = true
                    return
                }
                self.resetRequestedWhenIdle = false
                await self.stopCurrentSessionLocked(reason: reason, clearRecord: true)
            }
        } else {
            self.armIdleTimer()
        }
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
            await self.stopCurrentSessionLocked(reason: "manual reset", clearRecord: true)
        }
    }

    /// Drain PTY output so the write side doesn't block.
    func drainOutput() {
        self.process?.drainOutput()
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
            let canPersistRecord = if self.process == nil {
                self.reapRecordedSessionIfNeeded()
            } else {
                true
            }

            if let proc = self.process,
               proc.isRunning,
               self.binaryPath == binary,
               self.consecutiveProbeFailures < max(1, self.dependencies.failureRelaunchThreshold)
            {
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
                await self.stopCurrentSessionLocked(reason: reason, clearRecord: true)
            }

            let launched = try self.dependencies.launcher.launch(binary: binary)
            let launchedPID = launched.pid
            let binaryName = URL(fileURLWithPath: binary).lastPathComponent
            guard self.dependencies.registerForAppShutdown(launchedPID, binaryName) else {
                await self.terminateLaunchedProcess(launched)
                throw SessionError.launchFailed("App shutdown in progress")
            }

            let processGroup = launched.processGroup ?? launched.assignProcessGroup()
            self.dependencies.updateAppShutdownProcessGroup(launchedPID, processGroup)

            self.process = launched
            self.binaryPath = binary
            self.consecutiveProbeFailures = 0
            self.sessionGeneration &+= 1
            if canPersistRecord {
                self.persistRecord(pid: launchedPID, binary: binary, processGroup: processGroup)
            } else {
                self.persistedProcessIdentity = nil
            }

            Self.log.debug(
                "Antigravity CLI session started",
                metadata: [
                    "binary": binaryName,
                    "pid": "\(launchedPID)",
                ])
            return launchedPID
        }
    }

    private func cancelIdleTimer() {
        self.idleTask?.cancel()
        self.idleTask = nil
    }

    private func armIdleTimer() {
        guard self.process != nil, self.dependencies.idleWindow > 0 else { return }
        self.cancelIdleTimer()
        let generation = self.sessionGeneration
        let nanoseconds = Self.nanoseconds(from: self.dependencies.idleWindow)
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
            await self.stopCurrentSessionLocked(reason: "idle timeout", clearRecord: true)
        }
    }

    private func stopCurrentSessionLocked(reason: String, clearRecord: Bool) async {
        self.cancelIdleTimer()
        guard let proc = self.process else {
            if clearRecord {
                _ = self.reapRecordedSessionIfNeeded()
            }
            return
        }

        let pid = proc.pid
        let identity = self.persistedProcessIdentity
        Self.log.debug("Antigravity CLI session stopping", metadata: ["pid": "\(pid)", "reason": "\(reason)"])

        self.process = nil
        self.binaryPath = nil
        self.persistedProcessIdentity = nil
        self.sessionGeneration &+= 1

        await self.terminateLaunchedProcess(proc)
        self.dependencies.unregisterForAppShutdown(pid)
        if clearRecord {
            self.removeRecordIfMatches(pid: pid, identity: identity)
        }
    }

    private func terminateLaunchedProcess(_ proc: any AntigravityCLIProcessHandle) async {
        try? proc.sendExit()
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

    private func persistRecord(pid: pid_t, binary: String, processGroup: pid_t?) {
        guard let identity = self.dependencies.identityProvider.identity(for: pid) else {
            self.persistedProcessIdentity = nil
            return
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
        } catch {
            self.persistedProcessIdentity = nil
        }
    }

    @discardableResult
    private func reapRecordedSessionIfNeeded() -> Bool {
        guard let record = try? self.dependencies.recordStore.load() else { return true }
        guard let liveIdentity = self.dependencies.identityProvider.identity(for: record.pid) else {
            try? self.dependencies.recordStore.remove()
            return true
        }
        guard liveIdentity.executablePath == record.executablePath,
              abs(liveIdentity.startEpoch - record.startEpoch) < 0.001
        else {
            try? self.dependencies.recordStore.remove()
            return true
        }
        if let ownerPID = record.ownerPID,
           ownerPID != self.dependencies.currentProcessID(),
           let ownerExecutablePath = record.ownerExecutablePath,
           let ownerStartEpoch = record.ownerStartEpoch,
           let liveOwnerIdentity = self.dependencies.identityProvider.identity(for: ownerPID),
           liveOwnerIdentity.executablePath == ownerExecutablePath,
           abs(liveOwnerIdentity.startEpoch - ownerStartEpoch) < 0.001
        {
            Self.log.debug("Antigravity CLI session still owned by live process", metadata: [
                "pid": "\(record.pid)",
                "ownerPID": "\(ownerPID)",
            ])
            self.persistedProcessIdentity = nil
            return false
        }

        let knownDescendants = self.dependencies.descendantPIDs(record.pid)
        Self.log.debug("Reaping stale Antigravity CLI session", metadata: ["pid": "\(record.pid)"])
        self.dependencies.terminateProcessTree(record.pid, record.processGroup, SIGTERM, knownDescendants)
        self.dependencies.terminateProcessTree(record.pid, record.processGroup, SIGKILL, knownDescendants)
        try? self.dependencies.recordStore.remove()
        return true
    }

    private func removeRecordIfMatches(pid: pid_t, identity: AntigravityCLIProcessIdentity?) {
        guard let identity,
              let record = try? self.dependencies.recordStore.load(),
              record.pid == pid,
              record.executablePath == identity.executablePath,
              abs(record.startEpoch - identity.startEpoch) < 0.001
        else { return }
        try? self.dependencies.recordStore.remove()
    }

    private static func nanoseconds(from interval: TimeInterval) -> UInt64 {
        guard interval > 0 else { return 0 }
        let capped = min(interval, TimeInterval(UInt64.max) / 1_000_000_000)
        return UInt64(capped * 1_000_000_000)
    }
}

// MARK: - Production Process Implementation

struct AntigravityPTYProcessLauncher: AntigravityCLIProcessLaunching {
    func launch(binary: String) throws -> any AntigravityCLIProcessHandle {
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

        #if canImport(Darwin)
        let homeDirectory = NSHomeDirectory()
        _ = homeDirectory.withCString { path in
            posix_spawn_file_actions_addchdir_np(&fileActions, path)
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
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        var env = TTYCommandRunner.enrichedEnvironment()
        env["PWD"] = NSHomeDirectory()
        env["TERM"] = "xterm-256color"

        let cArgs: [UnsafeMutablePointer<CChar>?] = [strdup(binary), nil]
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
        let spawnResult = binary.withCString { execPath in
            posix_spawn(&pid, execPath, &fileActions, &attr, cArgs, cEnv)
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

    func drainOutput() {
        var tmp = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<64 {
            let n = read(self.primaryFD, &tmp, tmp.count)
            if n > 0 { continue }
            break
        }
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

struct AntigravityDarwinProcessIdentityProvider: AntigravityCLIProcessIdentityProviding {
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
        return nil
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

    func load() throws -> AntigravityCLISessionRecord? {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return nil }
        let data = try Data(contentsOf: self.fileURL)
        return try JSONDecoder().decode(AntigravityCLISessionRecord.self, from: data)
    }

    func save(_ record: AntigravityCLISessionRecord) throws {
        let directory = self.fileURL.deletingLastPathComponent()
        try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: self.fileURL, options: [.atomic])
    }

    func remove() throws {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return }
        try self.fileManager.removeItem(at: self.fileURL)
    }
}
