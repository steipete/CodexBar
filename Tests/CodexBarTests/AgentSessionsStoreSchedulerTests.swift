import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

private actor AgentSessionScanHarness {
    struct Call: Equatable, Sendable {
        let includeFileOnlySessions: Bool
    }

    private var calls: [Call] = []
    private var continuations: [Int: CheckedContinuation<[AgentSession], Never>] = [:]
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func scan(includeFileOnlySessions: Bool) async -> [AgentSession] {
        let index = self.calls.count
        self.calls.append(Call(includeFileOnlySessions: includeFileOnlySessions))
        self.resumeSatisfiedWaiters()
        return await withCheckedContinuation { continuation in
            self.continuations[index] = continuation
        }
    }

    func waitForCallCount(_ count: Int) async {
        guard self.calls.count < count else { return }
        await withCheckedContinuation { continuation in
            self.callWaiters.append((count, continuation))
        }
    }

    func releaseCall(_ index: Int, returning sessions: [AgentSession]) {
        self.continuations.removeValue(forKey: index)?.resume(returning: sessions)
    }

    func recordedCalls() -> [Call] {
        self.calls
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in self.callWaiters {
            if self.calls.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        self.callWaiters = remaining
    }
}

private actor AgentSessionRemoteFetchHarness {
    private var calls: [[String]] = []
    private var continuations: [Int: CheckedContinuation<[RemoteSessionHostResult], Never>] = [:]
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func fetch(hosts: [String]) async -> [RemoteSessionHostResult] {
        let index = self.calls.count
        self.calls.append(hosts)
        self.resumeSatisfiedWaiters()
        return await withCheckedContinuation { continuation in
            self.continuations[index] = continuation
        }
    }

    func waitForCallCount(_ count: Int) async {
        guard self.calls.count < count else { return }
        await withCheckedContinuation { continuation in
            self.callWaiters.append((count, continuation))
        }
    }

    func releaseCall(_ index: Int, returning results: [RemoteSessionHostResult]) {
        self.continuations.removeValue(forKey: index)?.resume(returning: results)
    }

    func recordedCalls() -> [[String]] {
        self.calls
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in self.callWaiters {
            if self.calls.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        self.callWaiters = remaining
    }
}

private actor AgentSessionRefreshSpy {
    private(set) var localCalls: [Bool] = []
    private(set) var remoteCalls: [[String]] = []
    private var localWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var remoteWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func scan(includeFileOnlySessions: Bool) -> [AgentSession] {
        self.localCalls.append(includeFileOnlySessions)
        self.resumeLocalWaiters()
        return []
    }

    func fetch(hosts: [String]) -> [RemoteSessionHostResult] {
        self.remoteCalls.append(hosts)
        self.resumeRemoteWaiters()
        return []
    }

    func waitForLocalCallCount(_ count: Int) async {
        guard self.localCalls.count < count else { return }
        await withCheckedContinuation { continuation in
            self.localWaiters.append((count, continuation))
        }
    }

    func waitForRemoteCallCount(_ count: Int) async {
        guard self.remoteCalls.count < count else { return }
        await withCheckedContinuation { continuation in
            self.remoteWaiters.append((count, continuation))
        }
    }

    private func resumeLocalWaiters() {
        let ready = self.localWaiters.filter { self.localCalls.count >= $0.count }
        self.localWaiters.removeAll { self.localCalls.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    private func resumeRemoteWaiters() {
        let ready = self.remoteWaiters.filter { self.remoteCalls.count >= $0.count }
        self.remoteWaiters.removeAll { self.remoteCalls.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

@MainActor
struct AgentSessionsStoreSchedulerTests {
    @Test
    func `periodic schedulers match all lifecycle and settings states`() {
        let settings = testSettingsStore(suiteName: "AgentSessionsStoreSchedulerTests-states")
        let store = Self.makeStore(settings: settings)

        #expect(store.schedulerState == .init(
            isStarted: false,
            hasLocalPeriodicTask: false,
            hasRemotePeriodicTask: false,
            hasLocalImmediateTask: false,
            hasRemoteImmediateTask: false))

        store.start()
        #expect(store.isStarted)
        #expect(!store.schedulerState.hasLocalPeriodicTask)
        #expect(!store.schedulerState.hasRemotePeriodicTask)

        settings.refreshFrequency = .adaptiveAgentAware
        settings.adaptiveActivityScanConsent = .allowed
        store.settingsDidChange(remoteConfigurationChanged: false)
        #expect(store.schedulerState.hasLocalPeriodicTask)
        #expect(!store.schedulerState.hasRemotePeriodicTask)

        settings.agentSessionsEnabled = true
        store.settingsDidChange()
        #expect(store.schedulerState.hasLocalPeriodicTask)
        #expect(store.schedulerState.hasRemotePeriodicTask)

        store.stop()
        #expect(store.schedulerState == .init(
            isStarted: false,
            hasLocalPeriodicTask: false,
            hasRemotePeriodicTask: false,
            hasLocalImmediateTask: false,
            hasRemoteImmediateTask: false))
    }

    @Test
    func `settings changes immediately enable and disable the owned schedulers`() async {
        let settings = testSettingsStore(suiteName: "AgentSessionsStoreSchedulerTests-enable-disable")
        let spy = AgentSessionRefreshSpy()
        let store = Self.makeStore(settings: settings, spy: spy)
        store.start()

        settings.refreshFrequency = .adaptiveAgentAware
        settings.adaptiveActivityScanConsent = .allowed
        store.settingsDidChange(remoteConfigurationChanged: false)
        await spy.waitForLocalCallCount(1)
        #expect(store.schedulerState.hasLocalPeriodicTask)
        #expect(!store.schedulerState.hasRemotePeriodicTask)
        #expect(await spy.localCalls == [false])

        settings.agentSessionsEnabled = true
        store.settingsDidChange()
        await spy.waitForLocalCallCount(2)
        await spy.waitForRemoteCallCount(1)
        #expect(store.schedulerState.hasLocalPeriodicTask)
        #expect(store.schedulerState.hasRemotePeriodicTask)
        #expect(await spy.localCalls == [false, true])

        settings.agentSessionsEnabled = false
        settings.adaptiveActivityScanConsent = .declined
        store.settingsDidChange()
        #expect(!store.schedulerState.hasLocalPeriodicTask)
        #expect(!store.schedulerState.hasRemotePeriodicTask)
        #expect(store.localSessions.isEmpty)
        #expect(store.remoteHosts.isEmpty)
        #expect(store.latestLocalActivityAt == nil)
        store.stop()
    }

    @Test
    func `rapid off then agent sessions transition rejects stale local data and retries once`() async {
        let settings = testSettingsStore(suiteName: "AgentSessionsStoreSchedulerTests-local-generation")
        settings.refreshFrequency = .adaptiveAgentAware
        settings.adaptiveActivityScanConsent = .allowed
        let scan = AgentSessionScanHarness()
        let store = Self.makeStore(settings: settings, scan: scan)
        store.start()
        await scan.waitForCallCount(1)

        settings.adaptiveActivityScanConsent = .declined
        store.settingsDidChange(remoteConfigurationChanged: false)
        #expect(!store.schedulerState.hasLocalPeriodicTask)

        settings.agentSessionsEnabled = true
        store.settingsDidChange()
        await scan.releaseCall(0, returning: [Self.session(id: "stale", activity: Date(timeIntervalSince1970: 1))])
        await scan.waitForCallCount(2)

        #expect(await scan.recordedCalls() == [
            .init(includeFileOnlySessions: false),
            .init(includeFileOnlySessions: true),
        ])
        #expect(store.localSessions.isEmpty)
        #expect(store.latestLocalActivityAt == nil)

        let current = Self.session(id: "current", activity: Date(timeIntervalSince1970: 2))
        await scan.releaseCall(1, returning: [current])
        await Self.waitForImmediateTasksToFinish(store)
        #expect(store.localSessions == [current])
        #expect(store.latestLocalActivityAt == current.lastActivityAt)
        #expect(await scan.recordedCalls().count == 2)
        store.stop()
    }

    @Test
    func `remote configuration change rejects stale data and retries with current hosts`() async {
        let settings = testSettingsStore(suiteName: "AgentSessionsStoreSchedulerTests-remote-generation")
        settings.agentSessionsEnabled = true
        settings.agentSessionsManualHosts = "old-host"
        let remote = AgentSessionRemoteFetchHarness()
        let store = Self.makeStore(settings: settings, remote: remote)
        store.start()
        await remote.waitForCallCount(1)

        settings.agentSessionsManualHosts = "new-host"
        store.settingsDidChange()
        await remote.releaseCall(0, returning: [
            RemoteSessionHostResult(host: "old-host", sessions: [], error: nil),
        ])
        await remote.waitForCallCount(2)

        #expect(await remote.recordedCalls() == [["old-host"], ["new-host"]])
        #expect(store.remoteHosts.isEmpty)

        let current = RemoteSessionHostResult(host: "new-host", sessions: [], error: nil)
        await remote.releaseCall(1, returning: [current])
        await Self.waitForImmediateTasksToFinish(store)
        #expect(store.remoteHosts == [current])
        store.stop()
    }

    @Test
    func `menu refresh overlaps coalesce without an extra local pass`() async {
        let settings = testSettingsStore(suiteName: "AgentSessionsStoreSchedulerTests-menu-coalescing")
        settings.agentSessionsEnabled = true
        let scan = AgentSessionScanHarness()
        let store = Self.makeStore(settings: settings, scan: scan)
        store.start()
        await scan.waitForCallCount(1)

        for _ in 0..<5 {
            store.refreshOnMenuOpen()
        }
        #expect(await scan.recordedCalls().count == 1)

        await scan.releaseCall(0, returning: [])
        await Self.waitForImmediateTasksToFinish(store)
        #expect(await scan.recordedCalls().count == 1)
        store.stop()
    }

    @Test
    func `stop cancels every owned task and blocks late publication`() async {
        let settings = testSettingsStore(suiteName: "AgentSessionsStoreSchedulerTests-stop")
        settings.refreshFrequency = .adaptiveAgentAware
        settings.adaptiveActivityScanConsent = .allowed
        let scan = AgentSessionScanHarness()
        let store = Self.makeStore(settings: settings, scan: scan)
        var updateCount = 0
        store.onUpdate = { updateCount += 1 }
        store.start()
        await scan.waitForCallCount(1)

        store.stop()
        #expect(!store.isStarted)
        #expect(!store.schedulerState.hasLocalPeriodicTask)
        #expect(!store.schedulerState.hasRemotePeriodicTask)
        #expect(!store.schedulerState.hasLocalImmediateTask)
        #expect(!store.schedulerState.hasRemoteImmediateTask)

        await scan.releaseCall(0, returning: [Self.session(id: "late", activity: Date())])
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(store.localSessions.isEmpty)
        #expect(store.latestLocalActivityAt == nil)
        #expect(updateCount == 0)
    }

    private static func makeStore(
        settings: SettingsStore,
        scan: AgentSessionScanHarness? = nil,
        remote: AgentSessionRemoteFetchHarness? = nil) -> AgentSessionsStore
    {
        AgentSessionsStore(
            settings: settings,
            localScan: { includeFileOnlySessions in
                guard let scan else { return [] }
                return await scan.scan(includeFileOnlySessions: includeFileOnlySessions)
            },
            remoteHostDiscovery: { [] },
            remoteFetch: { hosts in
                guard let remote else { return [] }
                return await remote.fetch(hosts: hosts)
            })
    }

    private static func makeStore(
        settings: SettingsStore,
        spy: AgentSessionRefreshSpy) -> AgentSessionsStore
    {
        AgentSessionsStore(
            settings: settings,
            localScan: { includeFileOnlySessions in
                await spy.scan(includeFileOnlySessions: includeFileOnlySessions)
            },
            remoteHostDiscovery: { [] },
            remoteFetch: { hosts in
                await spy.fetch(hosts: hosts)
            })
    }

    private static func waitForImmediateTasksToFinish(_ store: AgentSessionsStore) async {
        for _ in 0..<1000 {
            let state = store.schedulerState
            if !state.hasLocalImmediateTask, !state.hasRemoteImmediateTask {
                return
            }
            await Task.yield()
        }
        Issue.record("Agent session immediate refresh tasks did not finish")
    }

    private static func session(id: String, activity: Date?) -> AgentSession {
        AgentSession(
            id: id,
            provider: .codex,
            source: .cli,
            state: .active,
            pid: 42,
            cwd: "/Users/test/alpha",
            projectName: "alpha",
            startedAt: nil,
            lastActivityAt: activity,
            transcriptPath: nil,
            host: "local")
    }
}
