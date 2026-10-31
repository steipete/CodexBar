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
            settings.costUsageHosts = []
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
    }

    @Test
    func `checkbox intent preserves an unrelated CLI grant and removal requires fresh consent`() throws {
        let defaults = InMemoryUserDefaults(values: ["agentSessionsManualHosts": "devbox"])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        _ = try CodexBarCLI.configHostsMutation(.add, host: "mini", cost: true, in: defaults, lockURL: nil)
        settings.setCostUsageHost("devbox", enabled: true)
        #expect(settings.costUsageHosts == ["devbox", "mini"])
        _ = try CodexBarCLI.configHostsMutation(.remove, host: "devbox", cost: true, in: defaults, lockURL: nil)
        try #require(settings.costUsageHosts.contains("devbox"), "The checkbox still sees the old selection.")
        settings.setCostUsageHost("mini", enabled: true)
        #expect(settings.costUsageHosts == ["mini"])
        settings.agentSessionsManualHosts = "mini"
        settings.agentSessionsManualHosts = "mini,devbox"
        #expect(settings.costUsageHosts == ["mini"])
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
    func `host projection remains independent of a failed portable import`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        defaults.set(Data("invalid document".utf8), forKey: PreferencesDocument.pendingImportKey)
        _ = try CodexBarCLI.configHostsMutation(.add, host: "mini", cost: true, in: defaults, lockURL: nil)
        settings.consumePendingPreferencesImport()
        #expect(settings.agentSessionsManualHosts == "mini")
        #expect(settings.costUsageHosts == ["mini"])
        #expect(defaults.data(forKey: PreferencesDocument.pendingImportKey) != nil)
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

    @Test
    func `concurrent CLI writers and a Settings revocation retain every acknowledged change`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = root.appendingPathComponent("hosts.lock")
        let defaults = InMemoryUserDefaults(values: [
            "agentSessionsManualHosts": "devbox", "costUsageHosts": ["devbox"],
        ])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults, hostPreferencesLockURL: lock)
        let errors = LockIsolated<[String]>([])
        let group = DispatchGroup()
        for index in 0..<6 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    _ = try CodexBarCLI.configHostsMutation(
                        .add, host: "mini\(index)", cost: true, in: defaults, lockURL: lock)
                } catch { errors.setValue([String(describing: error)]) }
            }
        }
        settings.setCostUsageHost("devbox", enabled: false)
        try #require(group.wait(timeout: .now() + 5) == .success)
        #expect(errors.value.isEmpty)
        settings.consumePendingPreferencesImport()
        #expect(Set(settings.costUsageHosts) == Set((0..<6).map { "mini\($0)" }))
        #expect(Set(settings.selectableCostUsageHosts) == Set(["devbox"] + (0..<6).map { "mini\($0)" }))
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
