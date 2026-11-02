import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

@MainActor
struct HostPreferencesTests {
    @Test(arguments: [false, true], [false, true])
    func `Settings edits and CLI adds survive delivery and fresh initialization`(
        revokeSpend: Bool, cliFirst: Bool) throws
    {
        let defaults = InMemoryUserDefaults(values: [
            "agentSessionsManualHosts": "devbox", "costUsageHosts": ["devbox"],
        ])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        if cliFirst {
            _ = try CodexBarCLI.configHostsMutation(.add, host: "mini", cost: true, in: defaults, lockURL: nil)
        }
        if revokeSpend {
            settings.setCostUsageHost("devbox", enabled: false)
        } else {
            settings.agentSessionsManualHosts = "replacement"
        }
        if !cliFirst {
            _ = try CodexBarCLI.configHostsMutation(.add, host: "mini", cost: true, in: defaults, lockURL: nil)
        }
        settings.consumePendingPreferencesImport()
        #expect(settings.costUsageHosts == ["mini"])
        let hosts = RemoteSessionFetcher.sanitizedHosts(settings.agentSessionsManualHosts.components(separatedBy: ","))
        #expect(hosts == (revokeSpend ? ["devbox", "mini"] : ["replacement", "mini"]))
        let fresh = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(fresh.costUsageHosts == settings.costUsageHosts)
        #expect(fresh.agentSessionsManualHosts == settings.agentSessionsManualHosts)
    }

    @Test
    func `list exposes rejected tokens and removal preserves unrelated raw tokens`() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set(" DevBox ,bad host,-bad,BAD HOST,,devbox,mini,a\tb", forKey: "agentSessionsManualHosts")
        defaults.set(["DevBox", "DevBox", "ghost"], forKey: "costUsageHosts")
        let state = try HostPreferences.update(in: defaults, lockURL: nil) { _ in }.state
        #expect(state.costUsageHosts == ["DevBox"])
        let entries = CodexBarCLI.configHostsEntries(state)
        #expect(entries == [
            ConfigHostsEntry(host: "DevBox", valid: true, costUsage: true, check: nil),
            ConfigHostsEntry(host: "bad host", valid: false, costUsage: false, check: nil),
            ConfigHostsEntry(host: "-bad", valid: false, costUsage: false, check: nil),
            ConfigHostsEntry(host: "mini", valid: true, costUsage: false, check: nil),
            ConfigHostsEntry(host: "a\tb", valid: false, costUsage: false, check: nil),
        ])
        #expect(CodexBarCLI.renderConfigHostEntry(entries[1]) == "bad host: invalid for spend")
        let removed = try HostPreferences.removing("bad host", from: state, costOnly: false)
        #expect(removed.state.manualTokens == [" DevBox ", "-bad", "", "devbox", "mini", "a\tb"])
        #expect(removed.changed)
        let removedDash = try HostPreferences.removing("-bad", from: removed.state, costOnly: false)
        #expect(removedDash.state.manualTokens == [" DevBox ", "", "devbox", "mini", "a\tb"])
        let removedTab = try HostPreferences.removing("a\tb", from: removedDash.state, costOnly: false)
        #expect(removedTab.state.manualTokens == [" DevBox ", "", "devbox", "mini"])
        #expect(!CodexBarCLI.configHostsEntries(removedTab.state).contains { !$0.valid })
    }

    @Test
    func `dirty editor merges its delta while idle drafts preserve canonical values`() throws {
        let raw = " DevBox ,bad host,,"
        let defaults = InMemoryUserDefaults(values: ["agentSessionsManualHosts": raw, "costUsageHosts": ["DevBox"]])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        _ = try CodexBarCLI.configHostsMutation(.add, host: "mini", cost: true, in: defaults, lockURL: nil)
        _ = settings.editManualHosts(baseline: raw, draft: raw)
        #expect(defaults.string(forKey: "agentSessionsManualHosts") == raw + ",mini")
        let committed = settings.editManualHosts(baseline: raw, draft: " DevBox ,buildbox")
        #expect(committed == " DevBox ,buildbox,mini")
        #expect(settings.costUsageHosts == ["DevBox", "mini"])
        _ = try settings.editManualHosts(baseline: #require(committed), draft: "devbox,mini,buildbox")
        #expect(!settings.costUsageHosts.contains("DevBox"))
        #expect(!settings.costUsageHosts.contains("devbox"))
    }

    @Test
    func `removing and readding shared host revokes consent and invalid aliases are not selectable`() {
        let defaults = InMemoryUserDefaults(values: ["agentSessionsManualHosts": "A, B", "costUsageHosts": ["A", "B"]])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        settings.agentSessionsManualHosts = "B"
        settings.agentSessionsManualHosts = "A, B"
        #expect(settings.costUsageHosts == ["B"])
        settings.agentSessionsManualHosts = "A, B, bad/path"
        #expect(settings.selectableCostUsageHosts == ["A", "B"])
    }

    @Test
    func `pending imports refresh host configuration even when the document is invalid`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        defaults.set(Data("invalid document".utf8), forKey: PreferencesDocument.pendingImportKey)
        _ = try CodexBarCLI.configHostsMutation(.add, host: "mini", cost: true, in: defaults, lockURL: nil)
        settings.consumePendingPreferencesImport()
        #expect(settings.agentSessionsManualHosts == "mini")
        #expect(settings.costUsageHosts == ["mini"])
    }

    @Test
    func `Settings revocation waits for an in-flight real CLI transaction then keeps its added host`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = root.appendingPathComponent("hosts.lock")
        let defaults = PausedHostDefaults(values: [
            "agentSessionsManualHosts": "devbox", "costUsageHosts": ["devbox"],
        ])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults, hostPreferencesLockURL: lock)
        let group = DispatchGroup()
        let errors = LockIsolated<[String]>([])
        let revoking = DispatchSemaphore(value: 0)
        let revoked = DispatchSemaphore(value: 0)
        let waited = LockIsolated(false)
        defaults.pauseNextHostRead()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                _ = try CodexBarCLI.configHostsMutation(.add, host: "mini", cost: true, in: defaults, lockURL: lock)
            } catch { errors.setValue([String(describing: error)]) }
        }
        defer { defaults.resume.signal(); _ = group.wait(timeout: .now() + 5) }
        try #require(defaults.didRead.wait(timeout: .now() + 5) == .success)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave(); defaults.resume.signal() }
            guard revoking.wait(timeout: .now() + 5) == .success else { return }
            // The CLI remains paused after its actual read while the Settings writer waits.
            waited.setValue(revoked.wait(timeout: .now() + 0.15) == .timedOut)
        }
        revoking.signal()
        settings.setCostUsageHost("devbox", enabled: false)
        revoked.signal()
        try #require(group.wait(timeout: .now() + 5) == .success)
        #expect(waited.value && errors.value.isEmpty)
        settings.consumePendingPreferencesImport()
        #expect(settings.agentSessionsManualHosts == "devbox,mini")
        #expect(settings.costUsageHosts == ["mini"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: HostLaunchBoundary.allCases)
    func `spend host launch denies unavailable authority and preserves launch errors`(
        boundary: HostLaunchBoundary) async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lockURL: URL? = boundary == .missingLock ? nil : root.appendingPathComponent("hosts.lock")
        let defaults = InMemoryUserDefaults(values: [
            "agentSessionsManualHosts": "fixture-host", "costUsageHosts": ["fixture-host"],
        ])
        var settings: SettingsStore? = testSettingsStore(
            suiteName: #function,
            userDefaults: defaults,
            config: testConfigWithAllProvidersDisabled(),
            hostPreferencesLockURL: lockURL)
        defer { settings?.configFileWatcher?.stop() }
        weak let owner = settings
        let launch: SpendDashboardController.MachineRemoteLaunch
        let consent: @MainActor @Sendable (String) -> Bool
        do {
            let store = try #require(settings)
            try #require(store.costUsageHosts == ["fixture-host"])
            launch = store.spendHostLaunch
            consent = store.spendHostConsent
            if boundary == .consentReadFailure || boundary == .consentReleasedOwner {
                try #require(consent("fixture-host"), "The stored host must be allowed before the failure.")
            }
            store.configFileWatcher?.stop()
        }
        if boundary == .unavailableLock || boundary == .consentReadFailure {
            let lockURL = try #require(lockURL)
            try FileManager.default.removeItem(at: lockURL)
            try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)
            try #require(
                settings?.costUsageHosts == ["fixture-host"],
                "A stale allowed projection must remain available.")
        }
        if boundary == .releasedOwner || boundary == .consentReleasedOwner {
            settings = nil
            try #require(owner == nil, "The launch operation must not retain Settings.")
        }
        if boundary == .consentReadFailure || boundary == .consentReleasedOwner {
            #expect(!consent("fixture-host"), "A failed read or released owner must deny the previously allowed host.")
        } else {
            let invoked = LockIsolated(false)
            let outcome = await Task { @MainActor in
                if boundary == .cancelled { withUnsafeCurrentTask { $0?.cancel() } }
                try launch("fixture-host") {
                    invoked.setValue(true)
                    if boundary == .launchError { throw HostLaunchBoundary.launchError }
                }
            }.result
            #expect(invoked.value == (boundary == .launchError), "Only the launch-error control may invoke launch.")
            switch outcome {
            case .success:
                Issue.record("Missing authority must cancel rather than invoke launch.")
            case let .failure(error):
                if boundary == .launchError {
                    #expect(
                        error as? HostLaunchBoundary == .launchError,
                        "The launch error must pass through unchanged.")
                } else {
                    #expect(error is CancellationError)
                }
            }
        }
        #expect(defaults.stringArray(forKey: "costUsageHosts") == ["fixture-host"])
    }

    @Test
    func `failed host lock leaves both memory and persisted values unchanged`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A directory cannot be acquired as a regular-file lock.
        let defaults = InMemoryUserDefaults(values: ["agentSessionsManualHosts": "devbox"])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults, hostPreferencesLockURL: root)
        let previous = defaults.dictionaryRepresentation() as NSDictionary
        do {
            _ = try CodexBarCLI.configHostsMutation(.list, host: nil, cost: false, in: defaults, lockURL: root)
            Issue.record("The directory must reject a regular-file host lock.")
        } catch {
            #expect(error as? ManagedCodexAccountLockError == .unavailable)
        }
        settings.setCostUsageHost("devbox", enabled: true)
        settings.agentSessionsManualHosts = "replacement"
        #expect(!settings.refreshHostPreferences())
        #expect(settings.agentSessionsManualHosts == "devbox")
        #expect(settings.costUsageHosts.isEmpty)
        #expect(defaults.dictionaryRepresentation() as NSDictionary == previous)
    }
}

enum HostLaunchBoundary: CaseIterable, Error {
    case missingLock, unavailableLock, releasedOwner, cancelled, launchError, consentReadFailure, consentReleasedOwner
}

/// Pauses the production CLI after it reads the real canonical pair while holding its host lock.
private final class PausedHostDefaults: InMemoryUserDefaults, @unchecked Sendable {
    let didRead = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let pauseLock = NSLock()
    private var shouldPause = false

    func pauseNextHostRead() {
        self.pauseLock.withLock { self.shouldPause = true }
    }

    override func stringArray(forKey defaultName: String) -> [String]? {
        let value = super.stringArray(forKey: defaultName)
        let paused = self.pauseLock.withLock {
            guard defaultName == "costUsageHosts", self.shouldPause else { return false }
            self.shouldPause = false
            return true
        }
        if paused {
            self.didRead.signal()
            #expect(self.resume.wait(timeout: .now() + 5) == .success)
        }
        return value
    }
}
