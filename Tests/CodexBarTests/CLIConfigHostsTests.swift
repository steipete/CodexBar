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
    func `config hosts remove options accept cost and reject check`() throws {
        let parser = CommandParser(signature: CommandSignature.describe(ConfigHostsRemoveOptions()).flattened())
        let parsed = try parser.parse(arguments: ["mini", "--cost"])

        #expect(parsed.positional == ["mini"])
        #expect(parsed.flags.contains("cost"))
        let invalidToken = try parser.parse(arguments: ["--format", "json", "--", "-bad"])
        #expect(invalidToken.positional == ["-bad"])
        #expect(invalidToken.options["format"] == ["json"])
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

        // Unset and empty stored hosts both resolve to no hosts; an empty queue override clears.
        let unset = try CodexBarCLI.configHostsState(in: InMemoryUserDefaults())
        #expect(unset.manualHosts.isEmpty)
        #expect(unset.costUsageHosts.isEmpty)

        let empty = InMemoryUserDefaults()
        empty.set("", forKey: "agentSessionsManualHosts")
        let emptyState = try CodexBarCLI.configHostsState(in: empty)
        #expect(emptyState.manualHosts.isEmpty)
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

    @Test(arguments: ["", "a;b", String(repeating: "x", count: 256)])
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

        // An identical retry, same or padded spelling, appends no duplicate token.
        let sameSpelling = ConfigHostsState(manualHosts: ["devbox"], costUsageHosts: ["devbox"])
        let retried = try CodexBarCLI.addedConfigHost("devbox", to: sameSpelling, cost: true)
        #expect(retried.state == sameSpelling)
        #expect(!retried.changed)
        #expect(retried.host == "devbox")

        let withCost = try CodexBarCLI.addedConfigHost("devbox", to: state, cost: true)
        #expect(withCost.state == state)
        #expect(!withCost.changed)

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

        // Only valid manual hosts count toward spend.
        let mixed = ConfigHostsState(manualHosts: ["devbox", "weird;host"], costUsageHosts: [])
        let added = try CodexBarCLI.addedConfigHost("mini", to: mixed, cost: true)
        #expect(added.state.manualHosts == ["devbox", "weird;host", "mini"])
        #expect(added.state.costUsageHosts == ["mini"])
        #expect(added.changed)
        #expect(added.host == "mini")
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

    @Test(arguments: ["", "one,two", "bad\nhost"])
    func `remove rejects ambiguous input`(host: String) {
        #expect(throws: (any Error).self) {
            _ = try CodexBarCLI.removedConfigHost(host, from: ConfigHostsState(), costOnly: false)
        }
    }

    @Test
    func `list exposes rejected tokens and removal preserves unrelated raw tokens`() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set(" DevBox ,bad host,-bad,BAD HOST,,devbox,mini", forKey: "agentSessionsManualHosts")
        let state = try CodexBarCLI.configHostsState(in: defaults)
        let entries = CodexBarCLI.configHostsEntries(state)
        #expect(entries.map(\.host) == ["DevBox", "bad host", "-bad", "mini"])
        #expect(entries.map(\.valid) == [true, false, false, true])
        let removed = try CodexBarCLI.removedConfigHost("bad host", from: state, costOnly: false)
        #expect(removed.state.manualTokens == [" DevBox ", "-bad", "", "devbox", "mini"])
        #expect(removed.changed)
        let removedDash = try CodexBarCLI.removedConfigHost("-bad", from: removed.state, costOnly: false)
        #expect(removedDash.state.manualTokens == [" DevBox ", "", "devbox", "mini"])
        #expect(!CodexBarCLI.configHostsEntries(removedDash.state).contains { !$0.valid })
        let absent = try CodexBarCLI.removedConfigHost("-bad", from: removedDash.state, costOnly: false)
        #expect(!absent.changed)
    }

    @Test
    func `add validates the adopted stored spelling`() {
        let state = ConfigHostsState(manualHosts: ["K"])
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
            in: defaults)

        let pending = try PreferencesDocument(
            queueData: #require(defaults.data(forKey: PreferencesDocument.pendingImportKey)))
        #expect(try pending.value("agentSessionsManualHosts", as: String.self) == "devbox")
        #expect(try pending.value("costUsageHosts", as: [String].self) == ["devbox"])

        try CodexBarCLI.queueConfigHosts(ConfigHostsState(manualHosts: [], costUsageHosts: []), in: defaults)
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
        #expect(CodexBarCLI.hostCheckFailureMessage.contains("--identified-only"))
    }

    @Test
    func `check rejects invalid inventory tokens without fetching`() async throws {
        let results = try await CodexBarCLI.checkConfigHosts(["bad host", "-bad"], fetch: { _ in
            Issue.record("An invalid stored token must never reach SSH")
        })
        #expect(results.count == 2)
        #expect(results.allSatisfy { !$0.ok && $0.error == RemoteCodexCostError.invalidHost.localizedDescription })
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
            try PreferencesDocument(data: Data(#"{"version":1,"preferences":{"costUsageHosts":[7]}}"#.utf8))
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
        try queued.queueImport(in: defaults)

        let document = try PreferencesDocument(defaults: defaults)
        #expect(try document.value("agentSessionsManualHosts", as: String.self) == nil)
        #expect(try document.value("costUsageHosts", as: [String].self) == nil)
    }

    @Test
    func `spend membership follows the app's exact-match load`() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set("DevBox", forKey: "agentSessionsManualHosts")
        defaults.set(["devbox"], forKey: "costUsageHosts")

        // The app's setter and load filter match spellings exactly; the queued view must not
        // report a selection pickup would clear.
        let state = try CodexBarCLI.configHostsState(in: defaults)
        #expect(state.manualHosts == ["DevBox"])
        #expect(state.costUsageHosts.isEmpty)
    }

    @Test
    func `add preserves stored entries it did not address`() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set("my host,mini", forKey: "agentSessionsManualHosts")

        let added = try CodexBarCLI.addedConfigHost(
            "devbox", to: CodexBarCLI.configHostsState(in: defaults), cost: true)
        try CodexBarCLI.queueConfigHosts(added.state, in: defaults)

        let pending = try PreferencesDocument(
            queueData: #require(defaults.data(forKey: PreferencesDocument.pendingImportKey)))
        #expect(try pending.value("agentSessionsManualHosts", as: String.self) == "my host,mini,devbox")
        #expect(try pending.value("costUsageHosts", as: [String].self) == ["devbox"])

        // The app view still sanitizes; the CLI inventory also exposes the invalid stored token.
        #expect(added.state.manualHosts == ["mini", "devbox"])
        #expect(CodexBarCLI.configHostsEntries(added.state).map(\.host) == ["my host", "mini", "devbox"])
        let settings = self.store("preserve", defaults: defaults)
        settings.consumePendingPreferencesImport()
        #expect(settings.agentSessionsManualHosts == "my host,mini,devbox")
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
}
