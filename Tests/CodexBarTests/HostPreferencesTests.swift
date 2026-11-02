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
        #expect(!settings.costUsageHosts.contains("devbox"))
        #expect(settings.costUsageHosts == ["mini"])
        let hosts = RemoteSessionFetcher.sanitizedHosts(settings.agentSessionsManualHosts.components(separatedBy: ","))
        #expect(hosts == (revokeSpend ? ["devbox", "mini"] : ["replacement", "mini"]))
        let fresh = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(fresh.costUsageHosts == settings.costUsageHosts)
        #expect(fresh.agentSessionsManualHosts == settings.agentSessionsManualHosts)
        if revokeSpend, cliFirst {
            settings.setCostUsageHost("devbox", enabled: true)
            _ = try CodexBarCLI.configHostsMutation(.remove, host: "devbox", cost: true, in: defaults, lockURL: nil)
            try #require(settings.costUsageHosts.contains("devbox"), "The checkbox still sees the old selection.")
            settings.setCostUsageHost("mini", enabled: true)
            #expect(settings.costUsageHosts == ["mini"])
        }
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
        defaults.set("DevBox", forKey: "agentSessionsManualHosts")
        defaults.set(["devbox"], forKey: "costUsageHosts")
        #expect(try HostPreferences.update(in: defaults, lockURL: nil) { _ in }.state.costUsageHosts.isEmpty)
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

    @Test(arguments: [false, true])
    func `pending imports refresh host configuration even when the document is invalid`(invalidDocument: Bool) throws {
        let defaults =
            InMemoryUserDefaults(values: invalidDocument ? [:] : ["agentSessionsManualHosts": "my host,mini"])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        if invalidDocument {
            defaults.set(Data("invalid document".utf8), forKey: PreferencesDocument.pendingImportKey)
        } else {
            var portable = PreferencesDocument()
            try portable.set("hidePersonalInfo", true)
            try portable.queueImport(in: defaults)
        }
        let host = invalidDocument ? "mini" : "devbox"
        _ = try CodexBarCLI.configHostsMutation(.add, host: host, cost: true, in: defaults, lockURL: nil)
        settings.consumePendingPreferencesImport()
        #expect(settings.agentSessionsManualHosts == (invalidDocument ? host : "my host,mini,devbox"))
        #expect(settings.costUsageHosts == [host])
        if !invalidDocument {
            #expect(settings.hidePersonalInfo)
            #expect(defaults.data(forKey: PreferencesDocument.pendingImportKey) == nil)
        }
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

    @Test(arguments: [false, true])
    func `spend host consent denies selected host after read failure or owner release`(releaseOwner: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lockURL = root.appendingPathComponent("hosts.lock")
        let defaults = InMemoryUserDefaults(values: [
            "agentSessionsManualHosts": "alpha", "costUsageHosts": ["alpha"],
        ])
        var settings: SettingsStore? = testSettingsStore(
            suiteName: #function,
            userDefaults: defaults,
            config: testConfigWithAllProvidersDisabled(),
            hostPreferencesLockURL: lockURL)
        defer { settings?.configFileWatcher?.stop() }
        weak let owner = settings
        let consent: @MainActor @Sendable (String) -> Bool
        do {
            let store = try #require(settings)
            consent = store.spendHostConsent
            try #require(consent("alpha"), "The stored host must be allowed before the failure.")
            try #require(store.costUsageHosts == ["alpha"])
            store.configFileWatcher?.stop()
        }
        if releaseOwner {
            settings = nil
            try #require(owner == nil, "The consent closure must not retain Settings.")
        } else {
            try FileManager.default.removeItem(at: lockURL)
            try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)
            try #require(settings?.costUsageHosts == ["alpha"], "A stale allowed projection must remain available.")
        }
        #expect(!consent("alpha"), "A failed read or released owner must deny the previously allowed host.")
        #expect(defaults.stringArray(forKey: "costUsageHosts") == ["alpha"])
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
            #expect(error.localizedDescription == "Could not acquire the CodexBar data lock.")
        }
        settings.setCostUsageHost("devbox", enabled: true)
        settings.agentSessionsManualHosts = "replacement"
        #expect(!settings.refreshHostPreferences())
        #expect(settings.agentSessionsManualHosts == "devbox")
        #expect(settings.costUsageHosts.isEmpty)
        #expect(defaults.dictionaryRepresentation() as NSDictionary == previous)
    }
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
