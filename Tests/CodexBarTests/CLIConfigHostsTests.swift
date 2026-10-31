import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

struct CLIConfigHostsTests {
    // MARK: Parsing

    @Test
    func `config hosts list options parse check format and domain`() throws {
        let parser = CommandParser(signature: CommandSignature.describe(ConfigHostsListOptions()).flattened())
        let parsed = try parser.parse(arguments: [
            "--check",
            "--format", "json",
            "--pretty",
            "--defaults-domain", "fixture-domain",
        ])

        #expect(parsed.flags.contains("check"))
        #expect(parsed.flags.contains("pretty"))
        #expect(parsed.options["format"] == ["json"])
        #expect(parsed.options["defaultsDomain"] == ["fixture-domain"])
        #expect(parsed.positional.isEmpty)
    }

    @Test
    func `config hosts add options parse host cost and check`() throws {
        let parser = CommandParser(signature: CommandSignature.describe(ConfigHostsAddOptions()).flattened())
        let parsed = try parser.parse(arguments: ["devbox", "--cost", "--check", "--json"])

        #expect(parsed.positional == ["devbox"])
        #expect(parsed.flags.contains("cost"))
        #expect(parsed.flags.contains("check"))
        #expect(parsed.flags.contains("jsonShortcut"))
    }

    @Test
    func `config hosts remove options accept cost and reject check`() throws {
        let parser = CommandParser(signature: CommandSignature.describe(ConfigHostsRemoveOptions()).flattened())
        let parsed = try parser.parse(arguments: ["mini", "--cost"])

        #expect(parsed.positional == ["mini"])
        #expect(parsed.flags.contains("cost"))
        #expect(throws: (any Error).self) { try parser.parse(arguments: ["mini", "--check"]) }
    }

    // MARK: State reads

    @Test
    func `host state reads defaults, sanitizes, and merges queued imports`() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set("devbox, Mini ,devbox,", forKey: "agentSessionsManualHosts")
        defaults.set(["devbox", "devbox"], forKey: "costUsageHosts")

        let state = try CodexBarCLI.configHostsState(in: defaults)
        #expect(state.manualHosts == ["devbox", "Mini"])
        #expect(state.costUsageHosts == ["devbox"])

        var queued = PreferencesDocument()
        try queued.set("agentSessionsManualHosts", "devbox, Mini, buildhost")
        try queued.set("costUsageHosts", ["devbox", "buildhost"])
        try queued.queueImport(in: defaults)

        let merged = try CodexBarCLI.configHostsState(in: defaults)
        #expect(merged.manualHosts == ["devbox", "Mini", "buildhost"])
        #expect(merged.costUsageHosts == ["devbox", "buildhost"])
    }

    @Test
    func `host state tolerates empty and unset defaults`() throws {
        let defaults = InMemoryUserDefaults()
        let state = try CodexBarCLI.configHostsState(in: defaults)
        #expect(state.manualHosts.isEmpty)
        #expect(state.costUsageHosts.isEmpty)

        defaults.set("", forKey: "agentSessionsManualHosts")
        let empty = try CodexBarCLI.configHostsState(in: defaults)
        #expect(empty.manualHosts.isEmpty)
    }

    // MARK: List entries

    @Test
    func `list entries mark invalid hosts and spend membership`() {
        let state = ConfigHostsState(manualHosts: ["devbox", "weird;host"], costUsageHosts: ["devbox"])

        let entries = CodexBarCLI.configHostsEntries(state)
        #expect(entries == [
            ConfigHostsEntry(host: "devbox", valid: true, costUsage: true, check: nil),
            ConfigHostsEntry(host: "weird;host", valid: false, costUsage: false, check: nil),
        ])
    }

    // MARK: Add

    @Test(arguments: ["", "   ", "-evil", "has space", "a;b", String(repeating: "x", count: 256)])
    func `add rejects invalid hosts`(host: String) {
        let state = ConfigHostsState(manualHosts: ["devbox"], costUsageHosts: ["devbox"])
        #expect(throws: (any Error).self) {
            _ = try CodexBarCLI.addedConfigHost(host, to: state, cost: false)
        }
    }

    @Test
    func `add is idempotent, case preserving, and trims input`() throws {
        let state = ConfigHostsState(manualHosts: ["DevBox"], costUsageHosts: ["DevBox"])

        let rerun = try CodexBarCLI.addedConfigHost(" devbox ", to: state, cost: false)
        #expect(rerun.state == state)
        #expect(!rerun.changed)
        // Reporting and checks use the stored spelling, never the raw argument.
        #expect(rerun.host == "DevBox")

        let withCost = try CodexBarCLI.addedConfigHost("devbox", to: state, cost: true)
        #expect(withCost.state == state)
        #expect(!withCost.changed)

        let added = try CodexBarCLI.addedConfigHost("mini", to: state, cost: true)
        #expect(added.state.manualHosts == ["DevBox", "mini"])
        #expect(added.state.costUsageHosts == ["DevBox", "mini"])
        #expect(added.changed)
        #expect(added.host == "mini")
    }

    @Test
    func `case variant cost membership uses the stored spelling`() throws {
        let state = ConfigHostsState(manualHosts: ["DevBox"], costUsageHosts: [])
        let result = try CodexBarCLI.addedConfigHost("devbox", to: state, cost: true)

        #expect(result.state.costUsageHosts == ["DevBox"])
        #expect(result.changed)
        #expect(result.host == "DevBox")
    }

    @Test
    func `distinct ssh usernames stay distinct`() throws {
        let state = ConfigHostsState(manualHosts: ["Alice@devbox", "alice@devbox"], costUsageHosts: [])
        let result = try CodexBarCLI.removedConfigHost("alice@devbox", from: state, costOnly: false)

        #expect(result.state.manualHosts == ["Alice@devbox"])
        #expect(result.changed)

        let added = try CodexBarCLI.addedConfigHost("alice@DevBox", to: result.state, cost: false)
        #expect(added.state.manualHosts == ["Alice@devbox", "alice@DevBox"])
    }

    @Test
    func `host state ignores unrelated invalid stored preferences`() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set("tomorrow", forKey: "refreshFrequency")
        defaults.set("devbox, mini", forKey: "agentSessionsManualHosts")
        defaults.set(["mini"], forKey: "costUsageHosts")

        let state = try CodexBarCLI.configHostsState(in: defaults)
        #expect(state.manualHosts == ["devbox", "mini"])
        #expect(state.costUsageHosts == ["mini"])
    }

    @Test
    func `add without cost leaves spend membership untouched`() throws {
        let state = ConfigHostsState(manualHosts: [], costUsageHosts: [])
        let result = try CodexBarCLI.addedConfigHost("devbox", to: state, cost: false)

        #expect(result.state.manualHosts == ["devbox"])
        #expect(result.state.costUsageHosts.isEmpty)
        #expect(result.changed)
    }

    @Test
    func `add with cost keeps only candidate spend hosts`() throws {
        let state = ConfigHostsState(manualHosts: ["devbox", "weird;host"], costUsageHosts: ["weird;host"])
        let result = try CodexBarCLI.addedConfigHost("mini", to: state, cost: true)

        #expect(result.state.manualHosts == ["devbox", "weird;host", "mini"])
        #expect(result.state.costUsageHosts == ["mini"])
        #expect(result.changed)
    }

    // MARK: Remove

    @Test
    func `remove drops the host from manual and spend lists`() throws {
        let state = ConfigHostsState(manualHosts: ["devbox", "mini"], costUsageHosts: ["devbox"])
        let result = try CodexBarCLI.removedConfigHost("devbox", from: state, costOnly: false)

        #expect(result.state.manualHosts == ["mini"])
        #expect(result.state.costUsageHosts.isEmpty)
        #expect(result.changed)
    }

    @Test
    func `remove with cost keeps the manual host`() throws {
        let state = ConfigHostsState(manualHosts: ["devbox"], costUsageHosts: ["devbox"])
        let result = try CodexBarCLI.removedConfigHost("devbox", from: state, costOnly: true)

        #expect(result.state.manualHosts == ["devbox"])
        #expect(result.state.costUsageHosts.isEmpty)
        #expect(result.changed)
    }

    @Test
    func `remove accepts hosts that fail strict validation`() throws {
        let state = ConfigHostsState(manualHosts: ["weird;host"], costUsageHosts: [])
        let result = try CodexBarCLI.removedConfigHost("weird;host", from: state, costOnly: false)

        #expect(result.state.manualHosts.isEmpty)
        #expect(result.changed)
    }

    @Test
    func `remove of an absent host is idempotent`() throws {
        let state = ConfigHostsState(manualHosts: ["devbox"], costUsageHosts: ["devbox"])

        let absent = try CodexBarCLI.removedConfigHost("ghost", from: state, costOnly: false)
        #expect(absent.state == state)
        #expect(!absent.changed)

        let costOnly = try CodexBarCLI.removedConfigHost("ghost", from: state, costOnly: true)
        #expect(costOnly.state == state)
        #expect(!costOnly.changed)
    }

    @Test
    func `remove rejects unsafe input`() {
        let state = ConfigHostsState(manualHosts: ["devbox"], costUsageHosts: [])
        #expect(throws: (any Error).self) {
            _ = try CodexBarCLI.removedConfigHost("-evil", from: state, costOnly: false)
        }
    }

    // MARK: Queued write

    @Test
    func `queuing host state writes only the two host keys and merges earlier queues`() throws {
        let defaults = InMemoryUserDefaults()
        var earlier = PreferencesDocument()
        try earlier.set("hidePersonalInfo", true)
        try earlier.queueImport(in: defaults)

        try CodexBarCLI.queueConfigHosts(
            ConfigHostsState(manualHosts: ["devbox"], costUsageHosts: ["devbox"]),
            in: defaults)

        let pending = try PreferencesDocument(
            data: #require(defaults.data(forKey: PreferencesDocument.pendingImportKey)))
        #expect(try pending.value("agentSessionsManualHosts", as: String.self) == "devbox")
        #expect(try pending.value("costUsageHosts", as: [String].self) == ["devbox"])
        #expect(try pending.value("hidePersonalInfo", as: Bool.self) == true)

        try CodexBarCLI.queueConfigHosts(ConfigHostsState(manualHosts: [], costUsageHosts: []), in: defaults)
        let emptied = try PreferencesDocument(
            data: #require(defaults.data(forKey: PreferencesDocument.pendingImportKey)))
        #expect(try emptied.value("agentSessionsManualHosts", as: String.self)?.isEmpty == true)
        #expect(try emptied.value("costUsageHosts", as: [String].self) == [])
        #expect(try emptied.value("hidePersonalInfo", as: Bool.self) == true)
    }

    // MARK: JSON shapes

    @Test
    func `list JSON shape keeps checks with explicit null errors`() throws {
        let result = ConfigHostsListResult(hosts: [
            ConfigHostsEntry(
                host: "devbox",
                valid: true,
                costUsage: true,
                check: ConfigHostsCheckResult(ok: true, error: nil)),
            ConfigHostsEntry(
                host: "weird;host",
                valid: false,
                costUsage: false,
                check: ConfigHostsCheckResult(ok: false, error: "Enter one SSH host alias or user@host.")),
            ConfigHostsEntry(host: "mini", valid: true, costUsage: false, check: nil),
        ])

        let json = try #require(CodexBarCLI.encodeJSON(result, pretty: false))
        let decoded = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let hosts = try #require(decoded["hosts"] as? [[String: Any]])
        #expect(hosts.count == 3)

        let ok = try #require(hosts[0]["check"] as? [String: Any])
        #expect(ok["ok"] as? Bool == true)
        #expect(ok["error"] is NSNull)

        let failed = try #require(hosts[1]["check"] as? [String: Any])
        #expect(failed["ok"] as? Bool == false)
        #expect(failed["error"] as? String == "Enter one SSH host alias or user@host.")

        #expect(hosts[2]["host"] as? String == "mini")
        #expect(hosts[2]["check"] == nil)
        #expect(hosts[2]["valid"] as? Bool == true)
    }

    @Test
    func `mutation JSON shape omits an absent check`() throws {
        let result = ConfigHostsMutationResult(host: "devbox", changed: true, costUsage: true, check: nil)
        let json = try #require(CodexBarCLI.encodeJSON(result, pretty: false))
        let decoded = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        #expect(decoded["host"] as? String == "devbox")
        #expect(decoded["changed"] as? Bool == true)
        #expect(decoded["costUsage"] as? Bool == true)
        #expect(decoded["check"] == nil)
    }

    // MARK: Check

    @Test
    func `check keeps the named failure cause per host`() async throws {
        let results = try await CodexBarCLI.checkConfigHosts(
            ["devbox", "weird;host", "brokenbox"],
            fetch: { host in
                // The real fetch validates hosts before SSH and fails closed on old CLIs.
                do { try RemoteCodexCostFetcher.validateHost(host) } catch { throw error }
                if host == "brokenbox" { throw RemoteCodexCostError.invalidReport }
            })

        #expect(results.count == 3)
        #expect(results[0] == ConfigHostsCheckResult(ok: true, error: nil))
        #expect(results[1].ok == false)
        #expect(results[1].error == "Enter one SSH host alias or user@host.")
        #expect(results[2].ok == false)
        #expect(results[2].error == RemoteCodexCostError.invalidReport.localizedDescription)
        #expect(CodexBarCLI.hostCheckError(CancellationError()) == CodexBarCLI.hostCheckFailureMessage)
    }

    @Test
    func `check maps cancellation to a thrown error`() async {
        do {
            _ = try await CodexBarCLI.checkConfigHosts(["devbox"], fetch: { _ in throw CancellationError() })
            Issue.record("Expected cancellation to propagate")
        } catch {
            #expect(error is CancellationError)
        }
    }
}

@MainActor
struct ConfigHostsPreferencesImportTests {
    private func store(_ suffix: String, defaults: UserDefaults) -> SettingsStore {
        testSettingsStore(suiteName: "ConfigHostsPreferences-\(suffix)", userDefaults: defaults)
    }

    @Test
    func `hosts document keys validate structurally and reject typed mismatches`() throws {
        var document = PreferencesDocument()
        try document.set("agentSessionsManualHosts", "devbox, Mini")
        try document.set("costUsageHosts", ["devbox", "Mini"])
        #expect(try String(data: document.encoded(), encoding: .utf8) != nil)

        for json in [
            #"{"version":1,"preferences":{"agentSessionsManualHosts":7}}"#,
            #"{"version":1,"preferences":{"costUsageHosts":"devbox"}}"#,
            #"{"version":1,"preferences":{"costUsageHosts":[7]}}"#,
        ] {
            #expect(throws: (any Error).self) { try PreferencesDocument(data: Data(json.utf8)) }
        }
    }

    @Test
    func `portable export excludes machine-local host keys`() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set("devbox, mini", forKey: "agentSessionsManualHosts")
        defaults.set(["devbox"], forKey: "costUsageHosts")

        let document = try PreferencesDocument(defaults: defaults)
        #expect(try document.value("agentSessionsManualHosts", as: String.self) == nil)
        #expect(try document.value("costUsageHosts", as: [String].self) == nil)
    }

    @Test
    func `session only add cannot resurrect a removed spend selection`() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set("devbox", forKey: "agentSessionsManualHosts")
        defaults.set(["devbox"], forKey: "costUsageHosts")

        let removed = try CodexBarCLI.removedConfigHost(
            "devbox", from: CodexBarCLI.configHostsState(in: defaults), costOnly: false)
        try CodexBarCLI.queueConfigHosts(removed.state, in: defaults)
        let added = try CodexBarCLI.addedConfigHost(
            "devbox", to: CodexBarCLI.configHostsState(in: defaults), cost: false)
        try CodexBarCLI.queueConfigHosts(added.state, in: defaults)

        let settings = self.store("resurrect", defaults: defaults)
        settings.consumePendingPreferencesImport()
        #expect(settings.agentSessionsManualHosts == "devbox")
        #expect(settings.costUsageHosts.isEmpty)
    }

    @Test
    func `case variant cost membership survives app pickup`() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set("DevBox", forKey: "agentSessionsManualHosts")

        let added = try CodexBarCLI.addedConfigHost(
            "devbox", to: CodexBarCLI.configHostsState(in: defaults), cost: true)
        try CodexBarCLI.queueConfigHosts(added.state, in: defaults)

        let settings = self.store("case-variant", defaults: defaults)
        settings.consumePendingPreferencesImport()
        #expect(settings.agentSessionsManualHosts == "DevBox")
        #expect(settings.costUsageHosts == ["DevBox"])
    }

    @Test
    func `importing hosts applies setters and the cost subset rule`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = self.store("import", defaults: defaults)

        var document = PreferencesDocument()
        try document.set("agentSessionsManualHosts", "devbox, Mini")
        try document.set("costUsageHosts", ["devbox", "Mini", "ghost;host"])
        try settings.importPreferences(document)

        #expect(settings.agentSessionsManualHosts == "devbox, Mini")
        #expect(settings.costUsageHosts == ["devbox", "Mini"])
        #expect(defaults.string(forKey: "agentSessionsManualHosts") == "devbox, Mini")
        #expect(defaults.stringArray(forKey: "costUsageHosts") == ["devbox", "Mini"])
    }

    @Test
    func `queued hosts import is consumed through setters at pickup`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = self.store("queued", defaults: defaults)

        var document = PreferencesDocument()
        try document.set("agentSessionsManualHosts", "buildhost")
        try document.set("costUsageHosts", ["buildhost"])
        try document.queueImport(in: defaults)

        settings.consumePendingPreferencesImport()
        #expect(settings.agentSessionsManualHosts == "buildhost")
        #expect(settings.costUsageHosts == ["buildhost"])
        #expect(defaults.data(forKey: PreferencesDocument.pendingImportKey) == nil)
    }

    @Test
    func `hosts import preserves other queued preferences`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = self.store("merge", defaults: defaults)

        var earlier = PreferencesDocument()
        try earlier.set("hidePersonalInfo", true)
        try earlier.queueImport(in: defaults)
        var hosts = PreferencesDocument()
        try hosts.set("agentSessionsManualHosts", "devbox")
        try hosts.queueImport(in: defaults)

        settings.consumePendingPreferencesImport()
        #expect(settings.agentSessionsManualHosts == "devbox")
        #expect(settings.costUsageHosts.isEmpty)
        #expect(settings.hidePersonalInfo)
    }
}
