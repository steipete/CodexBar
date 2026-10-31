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
    func `host state reads canonical defaults and sanitizes the spend subset`() throws {
        let defaults = InMemoryUserDefaults(values: [
            "agentSessionsManualHosts": "devbox, Mini ,devbox,",
            "costUsageHosts": ["devbox", "devbox", "ghost"],
        ])
        let state = try HostPreferences.update(in: defaults, lockURL: nil) { _ in }.state
        #expect(state.manualHosts == ["devbox", "Mini"])
        #expect(state.costUsageHosts == ["devbox"])
        defaults.set("DevBox", forKey: "agentSessionsManualHosts")
        defaults.set(["devbox"], forKey: "costUsageHosts")
        #expect(try HostPreferences.update(in: defaults, lockURL: nil) { _ in }.state.costUsageHosts.isEmpty)
    }

    // MARK: Add

    @Test(arguments: ["", "a;b", "k"])
    func `add rejects invalid hosts`(host: String) {
        // U+212A lowercases to k but fails the SSH host charset.
        let state = HostPreferences.State(
            manualTokens: [host == "k" ? "\u{212A}" : "devbox"],
            costUsageHosts: host == "k" ? [] : ["devbox"])
        #expect(throws: (any Error).self) {
            _ = try HostPreferences.adding(host, to: state, cost: false)
        }
    }

    @Test
    func `add is idempotent, case preserving, and trims input`() throws {
        let state = HostPreferences.State(manualTokens: ["DevBox"], costUsageHosts: ["DevBox"])

        let rerun = try HostPreferences.adding(" devbox ", to: state, cost: false)
        #expect(rerun.state == state)
        #expect(!rerun.changed)
        // Reporting and checks use the stored spelling, never the raw argument.
        #expect(rerun.host == "DevBox")

        let withCost = try HostPreferences.adding("devbox", to: state, cost: true)
        #expect(withCost.state == state)
        #expect(!withCost.changed)
        #expect(withCost.host == "DevBox")

        // Cost membership adopts the stored spelling, so the app's setter keeps it.
        let caseVariant = HostPreferences.State(manualTokens: ["DevBox"], costUsageHosts: [])
        let adopted = try HostPreferences.adding("devbox", to: caseVariant, cost: true)
        #expect(adopted.state.costUsageHosts == ["DevBox"])
        #expect(adopted.changed)
        #expect(adopted.host == "DevBox")

        // Without --cost the spend list is untouched.
        let untouched = try HostPreferences.adding("devbox", to: caseVariant, cost: false)
        #expect(untouched.state.manualHosts == ["DevBox"])
        #expect(untouched.state.costUsageHosts.isEmpty)
    }

    @Test
    func `distinct ssh usernames stay distinct`() throws {
        let state = HostPreferences.State(manualTokens: ["Alice@devbox", "alice@devbox"], costUsageHosts: [])
        let result = try HostPreferences.removing("alice@devbox", from: state, costOnly: false)

        #expect(result.state.manualHosts == ["Alice@devbox"])
        #expect(result.changed)

        let added = try HostPreferences.adding("alice@DevBox", to: result.state, cost: false)
        #expect(added.state.manualHosts == ["Alice@devbox", "alice@DevBox"])
    }

    // MARK: Remove

    @Test
    func `remove of an absent host is idempotent`() throws {
        let state = HostPreferences.State(manualTokens: ["devbox"], costUsageHosts: ["devbox"])

        let removedCost = try HostPreferences.removing("devbox", from: state, costOnly: true)
        #expect(removedCost.state.manualHosts == ["devbox"])
        #expect(removedCost.state.costUsageHosts.isEmpty)
        #expect(removedCost.changed)

        let absent = try HostPreferences.removing("ghost", from: state, costOnly: false)
        #expect(absent.state == state)
        #expect(!absent.changed)

        let costOnly = try HostPreferences.removing("ghost", from: state, costOnly: true)
        #expect(costOnly.state == state)
        #expect(!costOnly.changed)

        let unchanged = try HostPreferences.removing(
            "devbox", from: HostPreferences.State(manualTokens: ["devbox"]), costOnly: true)
        #expect(!unchanged.changed && unchanged.state.manualHosts == ["devbox"])
        #expect(CodexBarCLI.renderConfigHostMutation(
            ConfigHostsMutationResult(host: unchanged.host, changed: false, costUsage: false, check: nil),
            action: .remove,
            costOnly: true) == "Host unchanged: devbox")
    }

    @Test(arguments: ["", "one,two"])
    func `remove rejects ambiguous input`(host: String) {
        #expect(throws: (any Error).self) {
            _ = try HostPreferences.removing(host, from: HostPreferences.State(), costOnly: false)
        }
    }

    @Test
    func `list exposes rejected tokens and removal preserves unrelated raw tokens`() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set(" DevBox ,bad host,-bad,BAD HOST,,devbox,mini,a\tb", forKey: "agentSessionsManualHosts")
        defaults.set(["DevBox"], forKey: "costUsageHosts")
        let state = try HostPreferences.update(in: defaults, lockURL: nil) { _ in }.state
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

    // MARK: Canonical write

    @Test
    func `host transactions persist both canonical keys`() throws {
        let defaults = InMemoryUserDefaults()
        for action in [CodexBarCLI.ConfigHostsAction.add, .remove] {
            let result = try CodexBarCLI.configHostsMutation(
                action, host: "devbox", cost: action == .add, in: defaults, lockURL: nil)
            #expect(result.changed)
            #expect(defaults.string(forKey: "agentSessionsManualHosts") == (action == .add ? "devbox" : ""))
            #expect(defaults.stringArray(forKey: "costUsageHosts") == (action == .add ? ["devbox"] : []))
        }
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

        let mutation = ConfigHostsMutationResult(host: "devbox", changed: true, costUsage: true, check: nil)
        let mutationJSON = try #require(CodexBarCLI.encodeJSON(mutation, pretty: false))
        let decodedMutation = try #require(
            JSONSerialization.jsonObject(with: Data(mutationJSON.utf8)) as? [String: Any])
        #expect(decodedMutation["costUsage"] as? Bool == true)
        #expect(decodedMutation["check"] == nil)
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

    @Test(arguments: [false, true])
    func `cancelled check never starts another host after a suspended fetch finishes`(ordinaryFailure: Bool) async {
        struct SSHFailure: Error {}
        let started = AsyncStream<Void>.makeStream()
        let pending = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
        let calls = LockIsolated<[String]>([])
        let task = Task {
            try await CodexBarCLI.checkConfigHosts(["devbox", "mini"], fetch: { host in
                calls.setValue(calls.value + [host])
                if host == "devbox" {
                    await withCheckedContinuation {
                        pending.setValue($0)
                        started.continuation.yield(())
                        started.continuation.finish()
                    }
                }
                if ordinaryFailure { throw SSHFailure() }
            })
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        pending.value?.resume()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation to propagate")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(calls.value == ["devbox"])
    }
}
