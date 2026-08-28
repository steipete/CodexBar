import Foundation
@testable import CodexBarCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class KiroTestProcessRegistry: @unchecked Sendable {
    private struct Record {
        var processGroup: pid_t?
    }

    private let lock = NSLock()
    private let blockOnUnregister: Int?
    private let blockStartedURL: URL?
    private let unblock: DispatchSemaphore?
    private var records: [pid_t: Record] = [:]
    private var unregisteredPIDs: Set<pid_t> = []
    private var unregisterCount = 0

    init(
        blockOnUnregister: Int? = nil,
        blockStartedURL: URL? = nil,
        unblock: DispatchSemaphore? = nil)
    {
        self.blockOnUnregister = blockOnUnregister
        self.blockStartedURL = blockStartedURL
        self.unblock = unblock
    }

    deinit {
        self.terminateAll()
    }

    var dependencies: KiroStatusProbe.PipeProcessRegistry {
        .init(
            beginLaunch: { true },
            endLaunch: {},
            register: { pid, _ in
                self.lock.withLock {
                    self.records[pid] = Record(processGroup: nil)
                }
                return true
            },
            updateProcessGroup: { pid, processGroup in
                self.lock.withLock {
                    guard self.records[pid] != nil else { return }
                    self.records[pid]?.processGroup = processGroup
                }
            },
            unregister: { pid in
                let shouldBlock = self.lock.withLock {
                    self.records.removeValue(forKey: pid)
                    self.unregisteredPIDs.insert(pid)
                    self.unregisterCount += 1
                    return self.unregisterCount == self.blockOnUnregister
                }
                if shouldBlock {
                    if let blockStartedURL = self.blockStartedURL {
                        _ = FileManager.default.createFile(atPath: blockStartedURL.path, contents: Data())
                    }
                    self.unblock?.wait()
                }
            })
    }

    func isRegistered(_ pid: pid_t) -> Bool {
        self.lock.withLock { self.records[pid] != nil }
    }

    func didUnregister(_ pid: pid_t) -> Bool {
        self.lock.withLock { self.unregisteredPIDs.contains(pid) }
    }

    func activePIDs() -> Set<pid_t> {
        self.lock.withLock { Set(self.records.keys) }
    }

    func observedPIDs() -> Set<pid_t> {
        self.lock.withLock { self.unregisteredPIDs.union(self.records.keys) }
    }

    func terminate(_ pid: pid_t) {
        let processGroup = self.lock.withLock { () -> pid_t? in
            self.records[pid]?.processGroup
        }
        if let processGroup, processGroup > 0, processGroup != getpgrp() {
            _ = kill(-processGroup, SIGKILL)
        }
        if pid > 0 {
            _ = kill(pid, SIGKILL)
        }
    }

    func terminateAll() {
        let records = self.lock.withLock {
            let records = self.records
            self.records.removeAll()
            return records
        }
        for (pid, record) in records {
            if let processGroup = record.processGroup,
               processGroup > 0,
               processGroup != getpgrp()
            {
                _ = kill(-processGroup, SIGKILL)
            }
            if pid > 0 {
                _ = kill(pid, SIGKILL)
            }
        }
    }
}

enum KiroProcessTestSupport {
    private struct WaitTimeout: LocalizedError {
        let description: String
        let timeout: Duration

        var errorDescription: String? {
            "Timed out after \(self.timeout) waiting for \(self.description)"
        }
    }

    /// This bounds fixture setup only. Tests that exercise production timeout behavior pass their own exact budgets.
    static let fixtureSetupTimeout: Duration = .seconds(20)
    static let fixtureAccountTimeout: TimeInterval = 15

    static func makeFunctionalProbe(
        cliURL: URL,
        accountProbeTimeout: TimeInterval = fixtureAccountTimeout,
        usageProbeTimeout: TimeInterval = 20,
        contextProbeTimeout: TimeInterval = 15,
        pipeTimeoutCap: TimeInterval = 5,
        processRegistry: KiroTestProcessRegistry? = nil) -> KiroStatusProbe
    {
        let registry = processRegistry ?? KiroTestProcessRegistry()
        return KiroStatusProbe(
            cliBinaryResolver: { cliURL.path },
            accountProbeTimeout: accountProbeTimeout,
            usageProbeTimeout: usageProbeTimeout,
            contextProbeTimeout: contextProbeTimeout,
            pipeTimeoutCap: pipeTimeoutCap,
            pipeProcessRegistry: registry.dependencies)
    }

    static func waitForFile(
        _ url: URL,
        timeout: Duration = fixtureSetupTimeout) async throws
    {
        _ = try await self.wait(
            for: "fixture file \(url.path)",
            timeout: timeout)
        {
            FileManager.default.fileExists(atPath: url.path) ? true : nil
        }
    }

    static func waitForPID(
        in url: URL,
        timeout: Duration = fixtureSetupTimeout) async throws -> pid_t
    {
        try await self.wait(
            for: "a valid PID in fixture file \(url.path)",
            timeout: timeout)
        {
            self.readPID(from: url)
        }
    }

    static func waitForExit(
        of pid: pid_t,
        timeout: Duration,
        description: String) async throws
    {
        try await self.waitForExit(of: [pid], timeout: timeout, description: description)
    }

    static func waitForExit(
        of pids: [pid_t],
        timeout: Duration,
        description: String) async throws
    {
        _ = try await self.wait(for: description, timeout: timeout) {
            pids.allSatisfy { kill($0, 0) == -1 } ? true : nil
        }
    }

    static func readPID(from url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else {
            return nil
        }
        return pid
    }

    static func touch(_ url: URL) throws {
        let fileDescriptor = open(url.path, O_WRONLY | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        _ = close(fileDescriptor)
    }

    static func runTTYAfterFixtureReady(
        binary: URL,
        readyFile: URL,
        startFile: URL,
        options: TTYCommandRunner.Options,
        onURLDetected: (@Sendable () -> Void)? = nil) async throws -> TTYCommandRunner.Result
    {
        let task = Task.detached {
            try TTYCommandRunner().run(
                binary: binary.path,
                send: "",
                options: options,
                onURLDetected: onURLDetected)
        }
        do {
            try await self.waitForFile(readyFile)
            try self.touch(startFile)
        } catch {
            task.cancel()
            _ = try? await task.value
            throw error
        }
        return try await task.value
    }

    static func waitForCondition(
        _ description: String,
        timeout: Duration = fixtureSetupTimeout,
        condition: () -> Bool) async throws
    {
        _ = try await self.wait(for: description, timeout: timeout) {
            condition() ? true : nil
        }
    }

    private static func wait<Value>(
        for description: String,
        timeout: Duration,
        value: () -> Value?) async throws -> Value
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if let value = value() {
                return value
            }
            guard clock.now < deadline else {
                throw WaitTimeout(description: description, timeout: timeout)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

final class KiroTestInstantMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant?

    func mark() {
        self.lock.withLock {
            if self.instant == nil {
                self.instant = ContinuousClock().now
            }
        }
    }

    func value() -> ContinuousClock.Instant? {
        self.lock.withLock { self.instant }
    }
}

final class KiroTestCompletionMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func markCompleted() {
        self.lock.withLock { self.completed = true }
    }

    func isCompleted() -> Bool {
        self.lock.withLock { self.completed }
    }
}
