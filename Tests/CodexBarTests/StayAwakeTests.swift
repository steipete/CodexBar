import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct StayAwakeTests {
    private final class Assertions: @unchecked Sendable {
        private let lock = NSLock()
        private var acquired = 0
        private var released: [UInt32] = []
        var fail = false
        var counts: (Int, [UInt32]) {
            self.lock.withLock { (self.acquired, self.released) }
        }

        var api: AgentSessionPowerAssertion {
            AgentSessionPowerAssertion(acquire: {
                self.lock.withLock {
                    self.acquired += 1
                    return self.fail ? nil : 42
                }
            }, release: { id in self.lock.withLock { self.released.append(id) } })
        }
    }

    @Test
    func `preferences default off and survive a device-local reload`() {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: "awake-defaults", userDefaults: defaults)
        #expect(!settings.stayAwakeEnabled)
        #expect(!settings.credentialExpiryNotificationsEnabled)
        settings.stayAwakeEnabled = true
        settings.credentialExpiryNotificationsEnabled = true
        let reloaded = testSettingsStore(suiteName: "awake-reloaded", userDefaults: defaults)
        #expect(reloaded.stayAwakeEnabled)
        #expect(reloaded.credentialExpiryNotificationsEnabled)
    }

    @Test
    func `one assertion covers active and idle processes and ends with the last PID`() {
        let settings = testSettingsStore(suiteName: "awake-lifetime")
        let assertions = Assertions()
        let store = Self.store(settings, assertions)
        store.start()
        store.applyLocalScanResult([Self.session(pid: 42)])
        #expect(assertions.counts.0 == 0)
        settings.stayAwakeEnabled = true
        store.settingsDidChange(remoteConfigurationChanged: false)
        #expect(store.localMonitoringEnabled)
        #expect(store.schedulerState.hasLocalPeriodicTask)
        #expect(!store.schedulerState.hasRemotePeriodicTask)
        store.applyLocalScanResult([Self.session(pid: nil)])
        #expect(!store.isKeepingAwake)
        store.applyLocalScanResult([Self.session(pid: 42), Self.session(pid: 43)])
        store.applyLocalScanResult([Self.session(pid: 43, state: .idle)])
        #expect(store.isKeepingAwake)
        #expect(assertions.counts.0 == 1)
        #expect(store.localSessions.isEmpty)
        store.applyLocalScanResult([Self.session(pid: nil)])
        #expect(!store.isKeepingAwake)
        #expect(assertions.counts.1 == [42])
        store.stop()
    }

    @Test(arguments: [false, true])
    func `disable and shutdown release immediately and reject late results`(shutdown: Bool) {
        let settings = testSettingsStore(suiteName: "awake-stop-\(shutdown)")
        settings.stayAwakeEnabled = true
        let assertions = Assertions()
        let store = Self.store(settings, assertions)
        store.start()
        store.applyLocalScanResult([Self.session(pid: 42)])
        if shutdown {
            store.stop()
        } else {
            settings.stayAwakeEnabled = false
            store.settingsDidChange(remoteConfigurationChanged: false)
        }
        store.applyLocalScanResult([Self.session(pid: 42)])
        #expect(!store.isKeepingAwake)
        #expect(assertions.counts.0 == 1)
        #expect(assertions.counts.1 == [42])
        store.stop()
        #expect(assertions.counts.1 == [42])
    }

    @Test
    func `failed acquisition can retry and deinit releases only an acquired assertion`() {
        let settings = testSettingsStore(suiteName: "awake-failure")
        settings.stayAwakeEnabled = true
        let assertions = Assertions()
        assertions.fail = true
        var store: AgentSessionsStore? = Self.store(settings, assertions)
        store?.start()
        store?.applyLocalScanResult([Self.session(pid: 42)])
        #expect(store?.isKeepingAwake == false)
        assertions.fail = false
        store?.applyLocalScanResult([Self.session(pid: 42)])
        #expect(store?.isKeepingAwake == true)
        store = nil
        #expect(assertions.counts.0 == 2)
        #expect(assertions.counts.1 == [42])
    }

    @Test
    func `old scan cannot acquire after disabling and reenabling`() async throws {
        let settings = testSettingsStore(suiteName: "awake-stale")
        settings.stayAwakeEnabled = true
        let assertions = Assertions()
        let scan = DeferredScan()
        let store = AgentSessionsStore(
            settings: settings,
            localScan: { _ in await scan.scan() },
            remoteHostDiscovery: { [] },
            remoteFetch: { _ in [] },
            powerAssertion: assertions.api)
        store.start()
        try await scan.waitForCall(1)
        settings.stayAwakeEnabled = false
        store.settingsDidChange(remoteConfigurationChanged: false)
        settings.stayAwakeEnabled = true
        store.settingsDidChange(remoteConfigurationChanged: false)
        await scan.release([Self.session(pid: 42)])
        try await scan.waitForCall(2)
        #expect(assertions.counts.0 == 0)
        store.stop()
        await scan.release([Self.session(pid: 42)])
        await store.refreshLocal()
        #expect(assertions.counts.0 == 0)
    }

    private actor DeferredScan {
        var count = 0
        var continuation: CheckedContinuation<[AgentSession], Never>?
        func scan() async -> [AgentSession] {
            self.count += 1
            return await withCheckedContinuation { self.continuation = $0 }
        }

        func release(_ sessions: [AgentSession]) {
            self.continuation?.resume(returning: sessions)
            self.continuation = nil
        }

        func waitForCall(_ count: Int) async throws {
            // Other suites can hold MainActor during synchronous source audits.
            let deadline = ContinuousClock.now + .seconds(30)
            while self.count < count, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(self.count == count)
        }
    }

    private static func store(_ settings: SettingsStore, _ assertions: Assertions) -> AgentSessionsStore {
        AgentSessionsStore(
            settings: settings,
            localScan: { _ in [] },
            remoteHostDiscovery: { [] },
            remoteFetch: { _ in [] },
            powerAssertion: assertions.api,
            periodicSleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    }

    private static func session(pid: Int32?, state: AgentSession.State = .active) -> AgentSession {
        AgentSession(
            id: "synthetic",
            provider: .codex,
            source: .cli,
            state: state,
            pid: pid,
            cwd: nil,
            projectName: nil,
            startedAt: nil,
            lastActivityAt: nil,
            transcriptPath: nil,
            host: "local")
    }
}
