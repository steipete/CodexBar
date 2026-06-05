#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing
@testable import CodexBarCore

private final class FakeAntigravityProcessHandle: AntigravityCLIProcessHandle, @unchecked Sendable {
    private let lock = NSLock()
    let pid: pid_t
    var descendants: [pid_t]
    private var running: Bool
    private let terminateRootStopsProcess: Bool
    private var assignedProcessGroup: pid_t?
    private var events: [String] = []

    init(pid: pid_t, running: Bool = true, descendants: [pid_t] = [], terminateRootStopsProcess: Bool = true) {
        self.pid = pid
        self.running = running
        self.descendants = descendants
        self.terminateRootStopsProcess = terminateRootStopsProcess
    }

    var isRunning: Bool {
        self.lock.lock()
        let value = self.running
        self.events.append("isRunning:\(value)")
        self.lock.unlock()
        return value
    }

    var processGroup: pid_t? {
        self.lock.lock()
        let value = self.assignedProcessGroup
        self.lock.unlock()
        return value
    }

    func assignProcessGroup() -> pid_t? {
        self.lock.lock()
        self.assignedProcessGroup = self.pid
        self.events.append("assignProcessGroup")
        self.lock.unlock()
        return self.pid
    }

    func sendExit() throws {
        self.append("sendExit")
    }

    func closePTY() {
        self.append("closePTY")
    }

    func terminateRoot() {
        self.lock.lock()
        if self.terminateRootStopsProcess {
            self.running = false
        }
        self.events.append("terminateRoot")
        self.lock.unlock()
    }

    func killRoot() {
        self.lock.lock()
        self.running = false
        self.events.append("killRoot")
        self.lock.unlock()
    }

    func descendantPIDs() -> [pid_t] {
        self.lock.lock()
        let value = self.descendants
        self.events.append("descendantPIDs")
        self.lock.unlock()
        return value
    }

    func terminateTree(signal: Int32, knownDescendants _: [pid_t]) {
        self.lock.lock()
        if signal == SIGKILL {
            self.running = false
        }
        self.events.append("terminateTree:\(signal)")
        self.lock.unlock()
    }

    func killDescendants(_ descendants: [pid_t]) {
        self.append("killDescendants:\(descendants.map(String.init).joined(separator: ","))")
    }

    func drainOutput() {
        self.append("drainOutput")
    }

    func snapshotEvents() -> [String] {
        self.lock.lock()
        let value = self.events
        self.lock.unlock()
        return value
    }

    private func append(_ event: String) {
        self.lock.lock()
        self.events.append(event)
        self.lock.unlock()
    }
}

private final class FakeAntigravityProcessLauncher: AntigravityCLIProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var nextPID: pid_t
    private var launchError: Error?
    private var launchedBinaries: [String] = []
    private var terminateRootStopsProcess = true
    private var handles: [FakeAntigravityProcessHandle] = []

    init(nextPID: pid_t = 1) {
        self.nextPID = nextPID
    }

    func launch(binary: String) throws -> any AntigravityCLIProcessHandle {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let launchError {
            throw launchError
        }
        let handle = FakeAntigravityProcessHandle(
            pid: self.nextPID,
            descendants: [self.nextPID + 100],
            terminateRootStopsProcess: self.terminateRootStopsProcess)
        self.nextPID += 1
        self.launchedBinaries.append(binary)
        self.handles.append(handle)
        return handle
    }

    func setLaunchError(_ error: Error?) {
        self.lock.lock()
        self.launchError = error
        self.lock.unlock()
    }

    func setTerminateRootStopsProcess(_ value: Bool) {
        self.lock.lock()
        self.terminateRootStopsProcess = value
        self.lock.unlock()
    }

    func launchedBinarySnapshot() -> [String] {
        self.lock.lock()
        let value = self.launchedBinaries
        self.lock.unlock()
        return value
    }

    func handleSnapshot() -> [FakeAntigravityProcessHandle] {
        self.lock.lock()
        let value = self.handles
        self.lock.unlock()
        return value
    }
}

private final class FakeAntigravityIdentityProvider: AntigravityCLIProcessIdentityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [pid_t: AntigravityCLIProcessIdentity] = [:]

    func setIdentity(pid: pid_t, executablePath: String, startEpoch: TimeInterval) {
        self.lock.lock()
        self.identities[pid] = AntigravityCLIProcessIdentity(executablePath: executablePath, startEpoch: startEpoch)
        self.lock.unlock()
    }

    func removeIdentity(pid: pid_t) {
        self.lock.lock()
        self.identities[pid] = nil
        self.lock.unlock()
    }

    func identity(for pid: pid_t) -> AntigravityCLIProcessIdentity? {
        self.lock.lock()
        let value = self.identities[pid]
        self.lock.unlock()
        return value
    }
}

private final class MemoryAntigravitySessionRecordStore: AntigravityCLISessionRecordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var record: AntigravityCLISessionRecord?
    private var saves = 0
    private var removes = 0

    init(record: AntigravityCLISessionRecord? = nil) {
        self.record = record
    }

    func load() throws -> AntigravityCLISessionRecord? {
        self.lock.lock()
        let value = self.record
        self.lock.unlock()
        return value
    }

    func save(_ record: AntigravityCLISessionRecord) throws {
        self.lock.lock()
        self.record = record
        self.saves += 1
        self.lock.unlock()
    }

    func remove() throws {
        self.lock.lock()
        self.record = nil
        self.removes += 1
        self.lock.unlock()
    }

    func snapshot() -> AntigravityCLISessionRecord? {
        self.lock.lock()
        let value = self.record
        self.lock.unlock()
        return value
    }

    var saveCount: Int {
        self.lock.lock()
        let value = self.saves
        self.lock.unlock()
        return value
    }

    var removeCount: Int {
        self.lock.lock()
        let value = self.removes
        self.lock.unlock()
        return value
    }
}

private final class AntigravitySessionTerminationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(pid: pid_t, group: pid_t?, signal: Int32, descendants: [pid_t])] = []

    func append(pid: pid_t, group: pid_t?, signal: Int32, descendants: [pid_t]) {
        self.lock.lock()
        self.events.append((pid: pid, group: group, signal: signal, descendants: descendants))
        self.lock.unlock()
    }

    func snapshot() -> [(pid: pid_t, group: pid_t?, signal: Int32, descendants: [pid_t])] {
        self.lock.lock()
        let value = self.events
        self.lock.unlock()
        return value
    }
}

private final class AntigravityRegistryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldRegister = true
    private var registered: [pid_t] = []
    private var unregistered: [pid_t] = []
    private var groups: [pid_t: pid_t?] = [:]

    func setShouldRegister(_ value: Bool) {
        self.lock.lock()
        self.shouldRegister = value
        self.lock.unlock()
    }

    func register(pid: pid_t, _: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.shouldRegister else { return false }
        self.registered.append(pid)
        return true
    }

    func update(pid: pid_t, group: pid_t?) {
        self.lock.lock()
        self.groups[pid] = group
        self.lock.unlock()
    }

    func unregister(pid: pid_t) {
        self.lock.lock()
        self.unregistered.append(pid)
        self.lock.unlock()
    }

    func registeredSnapshot() -> [pid_t] {
        self.lock.lock()
        let value = self.registered
        self.lock.unlock()
        return value
    }

    func unregisteredSnapshot() -> [pid_t] {
        self.lock.lock()
        let value = self.unregistered
        self.lock.unlock()
        return value
    }
}

private final class AntigravityManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Error>] = []

    func sleep(_: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            self.continuations.append(continuation)
            self.lock.unlock()
        }
    }

    func resumeAll() {
        self.lock.lock()
        let continuations = self.continuations
        self.continuations.removeAll()
        self.lock.unlock()

        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitForSleeps(_ expectedCount: Int) async {
        for _ in 0..<200 {
            if self.pendingSleepCount >= expectedCount { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Timed out waiting for \(expectedCount) sleep continuation(s)")
    }

    private var pendingSleepCount: Int {
        self.lock.lock()
        let count = self.continuations.count
        self.lock.unlock()
        return count
    }
}

struct AntigravityCLISessionTests {
    @Test
    func `reuses alive process for same binary`() async throws {
        let fixture = self.makeFixture()
        fixture.identity.setIdentity(pid: 10, executablePath: "/bin/agy", startEpoch: 100)

        let firstPID = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)
        let secondPID = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)

        #expect(firstPID == 10)
        #expect(secondPID == 10)
        #expect(fixture.launcher.launchedBinarySnapshot() == ["/bin/agy"])
    }

    @Test
    func `relaunches when binary changes`() async throws {
        let fixture = self.makeFixture()
        fixture.identity.setIdentity(pid: 10, executablePath: "/bin/agy", startEpoch: 100)
        fixture.identity.setIdentity(pid: 11, executablePath: "/new/agy", startEpoch: 101)

        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)
        let secondPID = try await fixture.session.beginProbe(binary: "/new/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)

        #expect(secondPID == 11)
        #expect(fixture.launcher.launchedBinarySnapshot() == ["/bin/agy", "/new/agy"])
        #expect(fixture.registry.unregisteredSnapshot() == [10])
    }

    @Test
    func `replacement launch waits for in progress teardown`() async throws {
        let fixture = self.makeFixture(
            manualSleep: true,
            terminationGracePeriod: 1,
            terminateRootStopsProcess: false)
        fixture.identity.setIdentity(pid: 10, executablePath: "/old/agy", startEpoch: 100)
        fixture.identity.setIdentity(pid: 11, executablePath: "/new/agy", startEpoch: 101)

        _ = try await fixture.session.beginProbe(binary: "/old/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)

        let firstReplacement = Task {
            try await fixture.session.beginProbe(binary: "/new/agy")
        }
        await fixture.sleeper?.waitForSleeps(1)

        let secondReplacement = Task {
            try await fixture.session.beginProbe(binary: "/new/agy")
        }
        await Task.yield()
        #expect(fixture.launcher.launchedBinarySnapshot() == ["/old/agy"])

        fixture.launcher.handleSnapshot().first?.killRoot()
        fixture.sleeper?.resumeAll()
        let firstPID = try await firstReplacement.value
        let secondPID = try await secondReplacement.value
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)

        #expect(firstPID == 11)
        #expect(secondPID == 11)
        #expect(fixture.launcher.launchedBinarySnapshot() == ["/old/agy", "/new/agy"])
    }

    @Test
    func `replacement waits for active probe before relaunching`() async throws {
        let fixture = self.makeFixture()
        fixture.identity.setIdentity(pid: 10, executablePath: "/old/agy", startEpoch: 100)
        fixture.identity.setIdentity(pid: 11, executablePath: "/new/agy", startEpoch: 101)

        let firstPID = try await fixture.session.beginProbe(binary: "/old/agy")
        let replacement = Task {
            try await fixture.session.beginProbe(binary: "/new/agy")
        }
        await Task.yield()
        await Task.yield()

        #expect(firstPID == 10)
        #expect(fixture.launcher.launchedBinarySnapshot() == ["/old/agy"])
        #expect(fixture.registry.unregisteredSnapshot().isEmpty)

        await fixture.session.finishProbe(success: true, resetAfterFetch: false)
        let secondPID = try await replacement.value
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)

        #expect(secondPID == 11)
        #expect(fixture.launcher.launchedBinarySnapshot() == ["/old/agy", "/new/agy"])
        #expect(fixture.registry.unregisteredSnapshot() == [10])
    }

    @Test
    func `replacement ignores queued starters while waiting for active probe`() async throws {
        let fixture = self.makeFixture()
        fixture.identity.setIdentity(pid: 10, executablePath: "/old/agy", startEpoch: 100)
        fixture.identity.setIdentity(pid: 11, executablePath: "/new/agy", startEpoch: 101)

        _ = try await fixture.session.beginProbe(binary: "/old/agy")
        let firstReplacement = Task {
            try await fixture.session.beginProbe(binary: "/new/agy")
        }
        let secondReplacement = Task {
            try await fixture.session.beginProbe(binary: "/new/agy")
        }
        await Task.yield()
        await Task.yield()

        #expect(fixture.launcher.launchedBinarySnapshot() == ["/old/agy"])

        await fixture.session.finishProbe(success: true, resetAfterFetch: false)
        let didLaunchReplacement = await self.waitForLaunches(fixture.launcher, count: 2)
        #expect(didLaunchReplacement)
        if !didLaunchReplacement {
            await fixture.session.finishProbe(success: true, resetAfterFetch: false)
        }

        let firstPID = try await firstReplacement.value
        let secondPID = try await secondReplacement.value
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)

        #expect(firstPID == 11)
        #expect(secondPID == 11)
        #expect(fixture.launcher.launchedBinarySnapshot() == ["/old/agy", "/new/agy"])
    }

    @Test
    func `relaunches when existing process is dead`() async throws {
        let fixture = self.makeFixture()
        fixture.identity.setIdentity(pid: 10, executablePath: "/bin/agy", startEpoch: 100)
        fixture.identity.setIdentity(pid: 11, executablePath: "/bin/agy", startEpoch: 101)

        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)
        fixture.launcher.handleSnapshot().first?.terminateRoot()
        let secondPID = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)

        #expect(secondPID == 11)
        #expect(fixture.launcher.launchedBinarySnapshot() == ["/bin/agy", "/bin/agy"])
    }

    @Test
    func `pty launcher creates dedicated process group before returning`() throws {
        let launcher = AntigravityPTYProcessLauncher()
        let handle = try launcher.launch(binary: "/bin/cat")
        defer {
            handle.killRoot()
            handle.terminateTree(signal: SIGKILL, knownDescendants: [])
            handle.closePTY()
        }

        #expect(handle.processGroup == handle.pid)
        #expect(getpgid(handle.pid) == handle.pid)
    }

    @Test
    func `spawned PTY drain is bounded per call`() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-drain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try Data(repeating: 1, count: 8192 * 65).write(to: temp)
        let primaryFD = open(temp.path, O_RDONLY)
        guard primaryFD >= 0 else {
            Issue.record("Failed to open temporary drain input")
            return
        }
        let secondaryFD = open("/dev/null", O_RDONLY)
        guard secondaryFD >= 0 else {
            close(primaryFD)
            Issue.record("Failed to open /dev/null")
            return
        }
        let handle = AntigravitySpawnedPTYProcessHandle(
            pid: getpid(),
            processGroup: getpgrp(),
            primaryFD: primaryFD,
            primaryHandle: FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true),
            secondaryHandle: FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true))
        defer { handle.closePTY() }

        handle.drainOutput()

        #expect(lseek(primaryFD, 0, SEEK_CUR) == off_t(8192 * 64))
    }

    @Test
    func `registration failure tears down launched process`() async {
        let fixture = self.makeFixture()
        fixture.registry.setShouldRegister(false)

        await #expect(throws: AntigravityCLISession.SessionError.self) {
            _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        }

        let handle = fixture.launcher.handleSnapshot().first
        #expect(handle?.isRunning == false)
        #expect(handle?.snapshotEvents().contains("closePTY") == true)
        #expect(fixture.registry.registeredSnapshot().isEmpty)
    }

    @Test
    func `idle window tears down warm process`() async throws {
        let fixture = self.makeFixture(idleWindow: 0.05, manualSleep: true)
        fixture.identity.setIdentity(pid: 10, executablePath: "/bin/agy", startEpoch: 100)

        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)
        await fixture.sleeper?.waitForSleeps(1)
        fixture.sleeper?.resumeAll()
        await self.waitUntilStopped(fixture.session)

        #expect(await fixture.session.isRunning == false)
        #expect(fixture.registry.unregisteredSnapshot() == [10])
        #expect(fixture.store.snapshot() == nil)
    }

    @Test
    func `active probe prevents idle teardown until finish`() async throws {
        let fixture = self.makeFixture(idleWindow: 0.05, manualSleep: true)
        fixture.identity.setIdentity(pid: 10, executablePath: "/bin/agy", startEpoch: 100)

        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)
        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.sleeper?.waitForSleeps(1)
        fixture.sleeper?.resumeAll()
        await Task.yield()

        #expect(await fixture.session.isRunning)
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)
        await fixture.sleeper?.waitForSleeps(1)
        fixture.sleeper?.resumeAll()
        await self.waitUntilStopped(fixture.session)
        #expect(await fixture.session.isRunning == false)
    }

    @Test
    func `manual reset waits for active probe to finish`() async throws {
        let fixture = self.makeFixture()
        fixture.identity.setIdentity(pid: 10, executablePath: "/bin/agy", startEpoch: 100)

        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.reset()
        #expect(await fixture.session.isRunning)
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)

        #expect(await fixture.session.isRunning == false)
        #expect(fixture.registry.unregisteredSnapshot() == [10])
    }

    @Test
    func `reset reaps persisted stale session when no in memory process exists`() async {
        let store = MemoryAntigravitySessionRecordStore(record: AntigravityCLISessionRecord(
            pid: 777,
            requestedBinaryPath: "/bin/agy",
            executablePath: "/bin/agy",
            startEpoch: 42,
            processGroup: 777))
        let fixture = self.makeFixture(store: store)
        fixture.identity.setIdentity(pid: 777, executablePath: "/bin/agy", startEpoch: 42)

        await fixture.session.reset()

        let terminations = fixture.terminations.snapshot()
        #expect(terminations.map(\.signal) == [SIGTERM, SIGKILL])
        #expect(terminations.allSatisfy { $0.pid == 777 && $0.group == 777 })
        #expect(fixture.store.snapshot() == nil)
    }

    @Test
    func `reset preserves persisted session owned by another live process`() async {
        let store = MemoryAntigravitySessionRecordStore(record: AntigravityCLISessionRecord(
            pid: 777,
            requestedBinaryPath: "/bin/agy",
            executablePath: "/bin/agy",
            startEpoch: 42,
            processGroup: 777,
            ownerPID: 900,
            ownerExecutablePath: "/Applications/CodexBar.app/Contents/MacOS/CodexBar",
            ownerStartEpoch: 10))
        let fixture = self.makeFixture(store: store, currentProcessID: 901)
        fixture.identity.setIdentity(pid: 777, executablePath: "/bin/agy", startEpoch: 42)
        fixture.identity.setIdentity(
            pid: 900,
            executablePath: "/Applications/CodexBar.app/Contents/MacOS/CodexBar",
            startEpoch: 10)

        await fixture.session.reset()

        #expect(fixture.terminations.snapshot().isEmpty)
        #expect(fixture.store.snapshot() != nil)
    }

    @Test
    func `launch preserves persisted session owned by another live process`() async throws {
        let protectedRecord = AntigravityCLISessionRecord(
            pid: 777,
            requestedBinaryPath: "/bin/agy",
            executablePath: "/bin/agy",
            startEpoch: 42,
            processGroup: 777,
            ownerPID: 900,
            ownerExecutablePath: "/Applications/CodexBar.app/Contents/MacOS/CodexBar",
            ownerStartEpoch: 10)
        let store = MemoryAntigravitySessionRecordStore(record: protectedRecord)
        let fixture = self.makeFixture(store: store, currentProcessID: 901)
        fixture.identity.setIdentity(pid: 777, executablePath: "/bin/agy", startEpoch: 42)
        fixture.identity.setIdentity(
            pid: 900,
            executablePath: "/Applications/CodexBar.app/Contents/MacOS/CodexBar",
            startEpoch: 10)
        fixture.identity.setIdentity(pid: 10, executablePath: "/bin/agy", startEpoch: 100)

        let pid = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: true)

        #expect(pid == 10)
        #expect(fixture.terminations.snapshot().isEmpty)
        #expect(fixture.store.saveCount == 0)
        #expect(fixture.store.snapshot() == protectedRecord)
    }

    @Test
    func `binary-change relaunch preserves persisted session owned by another live process`() async throws {
        let protectedRecord = AntigravityCLISessionRecord(
            pid: 777,
            requestedBinaryPath: "/bin/agy",
            executablePath: "/bin/agy",
            startEpoch: 42,
            processGroup: 777,
            ownerPID: 900,
            ownerExecutablePath: "/Applications/CodexBar.app/Contents/MacOS/CodexBar",
            ownerStartEpoch: 10)
        let store = MemoryAntigravitySessionRecordStore(record: protectedRecord)
        let fixture = self.makeFixture(store: store, currentProcessID: 901)
        fixture.identity.setIdentity(pid: 777, executablePath: "/bin/agy", startEpoch: 42)
        fixture.identity.setIdentity(
            pid: 900,
            executablePath: "/Applications/CodexBar.app/Contents/MacOS/CodexBar",
            startEpoch: 10)
        fixture.identity.setIdentity(pid: 10, executablePath: "/bin/agy", startEpoch: 100)
        fixture.identity.setIdentity(pid: 11, executablePath: "/new/agy", startEpoch: 101)

        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)
        let relaunchedPID = try await fixture.session.beginProbe(binary: "/new/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: true)

        #expect(relaunchedPID == 11)
        #expect(fixture.store.saveCount == 0)
        #expect(fixture.store.snapshot() == protectedRecord)
    }

    @Test
    func `reused unrecorded session is persisted after protected owner exits`() async throws {
        let protectedRecord = AntigravityCLISessionRecord(
            pid: 777,
            requestedBinaryPath: "/bin/agy",
            executablePath: "/bin/agy",
            startEpoch: 42,
            processGroup: 777,
            ownerPID: 900,
            ownerExecutablePath: "/Applications/CodexBar.app/Contents/MacOS/CodexBar",
            ownerStartEpoch: 10)
        let store = MemoryAntigravitySessionRecordStore(record: protectedRecord)
        let fixture = self.makeFixture(store: store, currentProcessID: 901)
        fixture.identity.setIdentity(pid: 777, executablePath: "/bin/agy", startEpoch: 42)
        fixture.identity.setIdentity(
            pid: 900,
            executablePath: "/Applications/CodexBar.app/Contents/MacOS/CodexBar",
            startEpoch: 10)
        fixture.identity.setIdentity(
            pid: 901,
            executablePath: "/Applications/CodexBar.app/Contents/MacOS/CodexBar",
            startEpoch: 20)
        fixture.identity.setIdentity(pid: 10, executablePath: "/bin/agy", startEpoch: 100)

        let firstPID = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)
        fixture.identity.removeIdentity(pid: 900)
        let secondPID = try await fixture.session.beginProbe(binary: "/bin/agy")
        let record = fixture.store.snapshot()
        await fixture.session.finishProbe(success: true, resetAfterFetch: true)
        #expect(firstPID == 10)
        #expect(secondPID == 10)
        #expect(fixture.launcher.launchedBinarySnapshot() == ["/bin/agy"])
        #expect(fixture.terminations.snapshot().map(\.pid) == [777, 777])
        #expect(fixture.store.saveCount == 1)
        #expect(record?.pid == 10)
        #expect(record?.ownerPID == 901)
    }

    @Test
    func `reset rechecks protected persisted session after owner exits`() async {
        let store = MemoryAntigravitySessionRecordStore(record: AntigravityCLISessionRecord(
            pid: 777,
            requestedBinaryPath: "/bin/agy",
            executablePath: "/bin/agy",
            startEpoch: 42,
            processGroup: 777,
            ownerPID: 900,
            ownerExecutablePath: "/Applications/CodexBar.app/Contents/MacOS/CodexBar",
            ownerStartEpoch: 10))
        let fixture = self.makeFixture(store: store, currentProcessID: 901)
        fixture.identity.setIdentity(pid: 777, executablePath: "/bin/agy", startEpoch: 42)
        fixture.identity.setIdentity(
            pid: 900,
            executablePath: "/Applications/CodexBar.app/Contents/MacOS/CodexBar",
            startEpoch: 10)

        await fixture.session.reset()
        fixture.identity.removeIdentity(pid: 900)
        await fixture.session.reset()

        let terminations = fixture.terminations.snapshot()
        #expect(terminations.map(\.signal) == [SIGTERM, SIGKILL])
        #expect(terminations.allSatisfy { $0.pid == 777 && $0.group == 777 })
        #expect(fixture.store.snapshot() == nil)
    }

    @Test
    func `teardown preserves record written by another live session`() async throws {
        let fixture = self.makeFixture()
        fixture.identity.setIdentity(pid: 10, executablePath: "/bin/agy", startEpoch: 100)

        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        let otherRecord = AntigravityCLISessionRecord(
            pid: 777,
            requestedBinaryPath: "/other/agy",
            executablePath: "/other/agy",
            startEpoch: 42,
            processGroup: 777)
        try fixture.store.save(otherRecord)
        await fixture.session.finishProbe(success: true, resetAfterFetch: true)

        #expect(fixture.store.snapshot() == otherRecord)
    }

    @Test
    func `force killed process is polled again so the child can be reaped`() async throws {
        let fixture = self.makeFixture(terminateRootStopsProcess: false)
        fixture.identity.setIdentity(pid: 10, executablePath: "/bin/agy", startEpoch: 100)
        fixture.identity.setIdentity(pid: 900, executablePath: "/app/CodexBar", startEpoch: 1)

        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: true)

        let events = fixture.launcher.handleSnapshot().first?.snapshotEvents() ?? []
        guard let killIndex = events.firstIndex(of: "terminateTree:\(SIGKILL)") else {
            Issue.record("Expected SIGKILL during teardown")
            return
        }
        #expect(events.dropFirst(killIndex + 1).contains("isRunning:false"))
    }

    @Test
    func `one shot CLI reset tears down after fetch`() async throws {
        let fixture = self.makeFixture()
        fixture.identity.setIdentity(pid: 10, executablePath: "/bin/agy", startEpoch: 100)

        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: true)

        #expect(await fixture.session.isRunning == false)
        #expect(fixture.registry.unregisteredSnapshot() == [10])
    }

    @Test
    func `one shot CLI reset is deferred until all active probes finish`() async throws {
        let fixture = self.makeFixture()
        fixture.identity.setIdentity(pid: 10, executablePath: "/bin/agy", startEpoch: 100)

        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        _ = try await fixture.session.beginProbe(binary: "/bin/agy")

        await fixture.session.finishProbe(success: true, resetAfterFetch: true)
        #expect(await fixture.session.isRunning)

        await fixture.session.finishProbe(success: true, resetAfterFetch: false)

        #expect(await fixture.session.isRunning == false)
        #expect(fixture.registry.unregisteredSnapshot() == [10])
    }

    @Test
    func `repeated probe failures relaunch session`() async throws {
        let fixture = self.makeFixture(failureRelaunchThreshold: 2)
        fixture.identity.setIdentity(pid: 10, executablePath: "/bin/agy", startEpoch: 100)
        fixture.identity.setIdentity(pid: 11, executablePath: "/bin/agy", startEpoch: 101)

        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: false, resetAfterFetch: false)
        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: false, resetAfterFetch: false)
        let relaunchedPID = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)

        #expect(relaunchedPID == 11)
        #expect(fixture.launcher.launchedBinarySnapshot() == ["/bin/agy", "/bin/agy"])
        #expect(await fixture.session.failureCountForTesting == 0)
    }

    @Test
    func `success resets failure counter`() async throws {
        let fixture = self.makeFixture(failureRelaunchThreshold: 2)
        fixture.identity.setIdentity(pid: 10, executablePath: "/bin/agy", startEpoch: 100)

        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: false, resetAfterFetch: false)
        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)
        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: false, resetAfterFetch: false)

        #expect(fixture.launcher.launchedBinarySnapshot() == ["/bin/agy"])
        #expect(await fixture.session.failureCountForTesting == 1)
    }

    @Test
    func `matching persisted stale process is reaped when resolved binary changed`() async throws {
        let store = MemoryAntigravitySessionRecordStore(record: AntigravityCLISessionRecord(
            pid: 777,
            requestedBinaryPath: "/old/agy",
            executablePath: "/old/agy",
            startEpoch: 42,
            processGroup: 777))
        let fixture = self.makeFixture(store: store)
        fixture.identity.setIdentity(pid: 777, executablePath: "/old/agy", startEpoch: 42)
        fixture.identity.setIdentity(pid: 10, executablePath: "/new/agy", startEpoch: 100)

        _ = try await fixture.session.beginProbe(binary: "/new/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)

        let terminations = fixture.terminations.snapshot()
        #expect(terminations.map(\.signal) == [SIGTERM, SIGKILL])
        #expect(terminations.allSatisfy { $0.pid == 777 && $0.group == 777 })
    }

    @Test
    func `matching persisted stale process is reaped before launch`() async throws {
        let store = MemoryAntigravitySessionRecordStore(record: AntigravityCLISessionRecord(
            pid: 777,
            requestedBinaryPath: "/bin/agy",
            executablePath: "/bin/agy",
            startEpoch: 42,
            processGroup: 777))
        let fixture = self.makeFixture(store: store)
        fixture.identity.setIdentity(pid: 777, executablePath: "/bin/agy", startEpoch: 42)
        fixture.identity.setIdentity(pid: 10, executablePath: "/bin/agy", startEpoch: 100)

        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)

        let terminations = fixture.terminations.snapshot()
        #expect(terminations.map(\.signal) == [SIGTERM, SIGKILL])
        #expect(terminations.allSatisfy { $0.pid == 777 && $0.group == 777 })
    }

    @Test
    func `non matching persisted process is not reaped`() async throws {
        let store = MemoryAntigravitySessionRecordStore(record: AntigravityCLISessionRecord(
            pid: 777,
            requestedBinaryPath: "/bin/agy",
            executablePath: "/bin/agy",
            startEpoch: 42,
            processGroup: 777))
        let fixture = self.makeFixture(store: store)
        fixture.identity.setIdentity(pid: 777, executablePath: "/usr/bin/other", startEpoch: 42)
        fixture.identity.setIdentity(pid: 10, executablePath: "/bin/agy", startEpoch: 100)

        _ = try await fixture.session.beginProbe(binary: "/bin/agy")
        await fixture.session.finishProbe(success: true, resetAfterFetch: false)

        #expect(fixture.terminations.snapshot().isEmpty)
    }

    private func waitForLaunches(_ launcher: FakeAntigravityProcessLauncher, count: Int) async -> Bool {
        for _ in 0..<200 {
            if launcher.launchedBinarySnapshot().count >= count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }

    private func waitUntilStopped(_ session: AntigravityCLISession) async {
        for _ in 0..<200 {
            let running = await session.isRunning
            if !running { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for Antigravity CLI session to stop")
    }

    private struct Fixture {
        let session: AntigravityCLISession
        let launcher: FakeAntigravityProcessLauncher
        let identity: FakeAntigravityIdentityProvider
        let store: MemoryAntigravitySessionRecordStore
        let terminations: AntigravitySessionTerminationRecorder
        let registry: AntigravityRegistryRecorder
        let sleeper: AntigravityManualSleeper?
    }

    private func makeFixture(
        store: MemoryAntigravitySessionRecordStore = MemoryAntigravitySessionRecordStore(),
        idleWindow: TimeInterval = 3600,
        failureRelaunchThreshold: Int = 2,
        manualSleep: Bool = false,
        terminationGracePeriod: TimeInterval = 0,
        terminateRootStopsProcess: Bool = true,
        currentProcessID: pid_t = 900) -> Fixture
    {
        let launcher = FakeAntigravityProcessLauncher(nextPID: 10)
        launcher.setTerminateRootStopsProcess(terminateRootStopsProcess)
        let identity = FakeAntigravityIdentityProvider()
        let terminations = AntigravitySessionTerminationRecorder()
        let registry = AntigravityRegistryRecorder()
        let sleeper = manualSleep ? AntigravityManualSleeper() : nil
        let session = AntigravityCLISession(dependencies: AntigravityCLISession.Dependencies(
            launcher: launcher,
            identityProvider: identity,
            recordStore: store,
            registerForAppShutdown: { pid, binary in registry.register(pid: pid, binary) },
            updateAppShutdownProcessGroup: { pid, group in registry.update(pid: pid, group: group) },
            unregisterForAppShutdown: { pid in registry.unregister(pid: pid) },
            descendantPIDs: { pid in [pid + 1, pid + 2] },
            terminateProcessTree: { pid, group, signal, descendants in
                terminations.append(pid: pid, group: group, signal: signal, descendants: descendants)
            },
            currentProcessID: { currentProcessID },
            now: Date.init,
            sleep: { nanoseconds in
                if let sleeper {
                    try await sleeper.sleep(nanoseconds)
                } else {
                    try await Task.sleep(nanoseconds: nanoseconds)
                }
            },
            idleWindow: idleWindow,
            failureRelaunchThreshold: failureRelaunchThreshold,
            terminationGracePeriod: terminationGracePeriod))
        return Fixture(
            session: session,
            launcher: launcher,
            identity: identity,
            store: store,
            terminations: terminations,
            registry: registry,
            sleeper: sleeper)
    }
}
