import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

struct CLIConfigHostsTests {
    // MARK: Parsing

    @Test
    func `config hosts list options expose the alternate defaults domain`() throws {
        let parser = CommandParser(signature: CommandSignature.describe(ConfigHostsListOptions()).flattened())
        let parsed = try parser.parse(arguments: ["--defaults-domain", "fixture-domain"])

        #expect(parsed.options["defaultsDomain"] == ["fixture-domain"])
        #expect(parsed.positional.isEmpty)
    }

    @Test
    func `config hosts remove rejects check`() throws {
        let parser = CommandParser(signature: CommandSignature.describe(ConfigHostsRemoveOptions()).flattened())
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
        try queued.queueImport(in: defaults, lockURL: nil)

        let merged = try CodexBarCLI.configHostsState(in: defaults)
        #expect(merged.manualHosts == ["devbox", "Mini", "buildhost"])
        #expect(merged.costUsageHosts == ["devbox", "buildhost"])

        // A queued empty value clears a nonempty persisted list, including its raw token array.
        var clear = PreferencesDocument()
        try clear.set("agentSessionsManualHosts", "")
        try clear.queueImport(in: defaults, lockURL: nil)
        let cleared = try CodexBarCLI.configHostsState(in: defaults)
        #expect(cleared.manualTokens.isEmpty)
        #expect(cleared.costUsageHosts.isEmpty)

        defaults.removeObject(forKey: PreferencesDocument.pendingImportKey)
        defaults.set("DevBox", forKey: "agentSessionsManualHosts")
        defaults.set(["devbox"], forKey: "costUsageHosts")
        let exactMatch = try CodexBarCLI.configHostsState(in: defaults)
        #expect(exactMatch.manualHosts == ["DevBox"])
        #expect(exactMatch.costUsageHosts.isEmpty)
    }

    // MARK: Add

    @Test(arguments: ["", "a;b"])
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
        #expect(withCost.host == "DevBox")

        // Cost membership adopts the stored spelling, so the app's setter keeps it.
        let caseVariant = ConfigHostsState(manualHosts: ["DevBox"], costUsageHosts: [])
        let adopted = try CodexBarCLI.addedConfigHost("devbox", to: caseVariant, cost: true)
        #expect(adopted.state.costUsageHosts == ["DevBox"])
        #expect(adopted.changed)
        #expect(adopted.host == "DevBox")

        // Without --cost the spend list is untouched.
        let untouched = try CodexBarCLI.addedConfigHost("devbox", to: caseVariant, cost: false)
        #expect(untouched.state.manualHosts == ["DevBox"])
        #expect(untouched.state.costUsageHosts.isEmpty)
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
    func `remove of an absent host is idempotent`() throws {
        let state = ConfigHostsState(manualHosts: ["devbox"], costUsageHosts: ["devbox"])

        let absent = try CodexBarCLI.removedConfigHost("ghost", from: state, costOnly: false)
        #expect(absent.state == state)
        #expect(!absent.changed)

        let costOnly = try CodexBarCLI.removedConfigHost("ghost", from: state, costOnly: true)
        #expect(costOnly.state == state)
        #expect(!costOnly.changed)
    }

    @Test(arguments: ["", "one,two"])
    func `remove rejects ambiguous input`(host: String) {
        #expect(throws: (any Error).self) {
            _ = try CodexBarCLI.removedConfigHost(host, from: ConfigHostsState(), costOnly: false)
        }
    }

    @Test
    func `list exposes rejected tokens and removal preserves unrelated raw tokens`() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set(" DevBox ,bad host,-bad,BAD HOST,,devbox,mini,a\tb", forKey: "agentSessionsManualHosts")
        defaults.set(["DevBox"], forKey: "costUsageHosts")
        let state = try CodexBarCLI.configHostsState(in: defaults)
        let entries = CodexBarCLI.configHostsEntries(state)
        #expect(entries == [
            ConfigHostsEntry(host: "DevBox", valid: true, costUsage: true, check: nil),
            ConfigHostsEntry(host: "bad host", valid: false, costUsage: false, check: nil),
            ConfigHostsEntry(host: "-bad", valid: false, costUsage: false, check: nil),
            ConfigHostsEntry(host: "mini", valid: true, costUsage: false, check: nil),
            ConfigHostsEntry(host: "a\tb", valid: false, costUsage: false, check: nil),
        ])
        let removed = try CodexBarCLI.removedConfigHost("bad host", from: state, costOnly: false)
        #expect(removed.state.manualTokens == [" DevBox ", "-bad", "", "devbox", "mini", "a\tb"])
        #expect(removed.changed)
        let removedDash = try CodexBarCLI.removedConfigHost("-bad", from: removed.state, costOnly: false)
        #expect(removedDash.state.manualTokens == [" DevBox ", "", "devbox", "mini", "a\tb"])
        let removedTab = try CodexBarCLI.removedConfigHost("a\tb", from: removedDash.state, costOnly: false)
        #expect(removedTab.state.manualTokens == [" DevBox ", "", "devbox", "mini"])
        #expect(!CodexBarCLI.configHostsEntries(removedTab.state).contains { !$0.valid })
    }

    @Test
    func `add validates the adopted stored spelling`() {
        // U+212A lowercases to k but fails the SSH host charset.
        let state = ConfigHostsState(manualHosts: ["\u{212A}"])
        for cost in [false, true] {
            #expect(throws: (any Error).self) {
                try CodexBarCLI.addedConfigHost("k", to: state, cost: cost)
            }
        }
    }

    // MARK: Queued write

    @Test
    func `queuing host state writes the host keys including an explicit empty clear`() throws {
        let defaults = InMemoryUserDefaults()

        try CodexBarCLI.queueConfigHosts(
            ConfigHostsState(manualHosts: ["devbox"], costUsageHosts: ["devbox"]),
            in: defaults,
            lockURL: nil)

        let pending = try PreferencesDocument(
            queueData: #require(defaults.data(forKey: PreferencesDocument.pendingImportKey)))
        #expect(try pending.value("agentSessionsManualHosts", as: String.self) == "devbox")
        #expect(try pending.value("costUsageHosts", as: [String].self) == ["devbox"])

        try CodexBarCLI.queueConfigHosts(
            ConfigHostsState(manualHosts: [], costUsageHosts: []),
            in: defaults,
            lockURL: nil)
        let emptied = try PreferencesDocument(
            queueData: #require(defaults.data(forKey: PreferencesDocument.pendingImportKey)))
        #expect(try emptied.value("agentSessionsManualHosts", as: String.self)?.isEmpty == true)
        #expect(try emptied.value("costUsageHosts", as: [String].self) == [])
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
        struct SSHFailure: Error {}
        let results = try await CodexBarCLI.checkConfigHosts(
            ["devbox", "brokenbox", "oldcli"],
            fetch: { host in
                if host == "brokenbox" { throw SSHFailure() }
                if host == "oldcli" { throw RemoteCodexCostError.invalidReport }
            })

        #expect(results.count == 3)
        #expect(results[0] == ConfigHostsCheckResult(ok: true, error: nil))
        #expect(results[1].ok == false)
        #expect(results[1].error == CodexBarCLI.hostCheckFailureMessage)
        #expect(results[2].ok == false)
        #expect(results[2].error == RemoteCodexCostError.invalidReport.localizedDescription)
        // The stock `.unavailable` text names --summary-only; this check never sends that flag.
        #expect(CodexBarCLI.hostCheckError(RemoteCodexCostError.unavailable) == CodexBarCLI.hostCheckFailureMessage)
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
    func `hosts document keys validate structurally`() throws {
        var document = PreferencesDocument()
        try document.set("agentSessionsManualHosts", "devbox, Mini")
        try document.set("costUsageHosts", ["devbox", "Mini"])
        #expect(try document.encoded().isEmpty == false)

        #expect(throws: (any Error).self) {
            try PreferencesDocument(queueData: Data(#"{"version":1,"preferences":{"costUsageHosts":[7]}}"#.utf8))
        }
    }

    @Test
    func `transferred preference files reject host keys`() throws {
        for json in [
            #"{"version":1,"preferences":{"agentSessionsManualHosts":"a;b,-oProxyCommand=x,ok"}}"#,
            #"{"version":1,"preferences":{"costUsageHosts":["a;b"]}}"#,
        ] {
            #expect(throws: (any Error).self) { try PreferencesDocument(data: Data(json.utf8)) }
        }
    }

    @Test
    func `portable export excludes machine-local host keys`() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set("devbox, mini", forKey: "agentSessionsManualHosts")
        defaults.set(["devbox"], forKey: "costUsageHosts")
        var queued = PreferencesDocument()
        try queued.set("agentSessionsManualHosts", "buildhost")
        try queued.set("costUsageHosts", ["buildhost"])
        try queued.queueImport(in: defaults, lockURL: nil)

        let document = try PreferencesDocument(defaults: defaults)
        #expect(try document.value("agentSessionsManualHosts", as: String.self) == nil)
        #expect(try document.value("costUsageHosts", as: [String].self) == nil)
    }

    @Test
    func `add preserves stored entries it did not address`() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set("my host,mini", forKey: "agentSessionsManualHosts")

        let added = try CodexBarCLI.addedConfigHost(
            "devbox", to: CodexBarCLI.configHostsState(in: defaults), cost: true)
        try CodexBarCLI.queueConfigHosts(added.state, in: defaults, lockURL: nil)

        let pending = try PreferencesDocument(
            queueData: #require(defaults.data(forKey: PreferencesDocument.pendingImportKey)))
        #expect(try pending.value("agentSessionsManualHosts", as: String.self) == "my host,mini,devbox")
        #expect(try pending.value("costUsageHosts", as: [String].self) == ["devbox"])
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

        try document.set("costUsageHosts", [String]())
        try settings.importPreferences(document)
        #expect(settings.agentSessionsManualHosts == "devbox, Mini")
        #expect(settings.costUsageHosts.isEmpty)
    }
}
