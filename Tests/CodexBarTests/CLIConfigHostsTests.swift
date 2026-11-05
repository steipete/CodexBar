import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

struct CLIConfigHostsTests {
    // MARK: Parsing

    @Test
    func `config hosts Commander parsing rejects unsupported remove check`() throws {
        let removeParser = CommandParser(signature: CommandSignature.describe(ConfigHostsRemoveOptions()).flattened())
        #expect(throws: (any Error).self) { try removeParser.parse(arguments: ["mini", "--check"]) }
    }

    // MARK: Add

    @Test(arguments: [
        ("", HostPreferences.State()),
        ("a;b", HostPreferences.State()),
        ("k", HostPreferences.State(manualTokens: ["\u{212A}"])),
    ])
    func `add rejects invalid hosts and stored case fold collisions`(host: String, state: HostPreferences.State) {
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

        let username = HostPreferences.State(manualTokens: ["Alice@devbox"])
        let added = try HostPreferences.adding("alice@DevBox", to: username, cost: false)
        #expect(added.state.manualHosts == ["Alice@devbox", "alice@DevBox"])
    }

    // MARK: Remove

    @Test
    func `remove clears consent and leaves absent hosts unchanged`() throws {
        let state = HostPreferences.State(manualTokens: ["devbox"], costUsageHosts: ["devbox"])

        let removedCost = try HostPreferences.removing("devbox", from: state, costOnly: true)
        #expect(removedCost.state.manualHosts == ["devbox"])
        #expect(removedCost.state.costUsageHosts.isEmpty)
        #expect(removedCost.changed)

        let absent = try HostPreferences.removing("ghost", from: state, costOnly: false)
        #expect(absent.state == state)
        #expect(!absent.changed)

        let unchanged = try HostPreferences.removing(
            "devbox", from: HostPreferences.State(manualTokens: ["devbox"]), costOnly: true)
        #expect(!unchanged.changed && unchanged.state.manualHosts == ["devbox"])

        let usernames = HostPreferences.State(manualTokens: ["Alice@devbox", "alice@devbox"])
        let removedUsername = try HostPreferences.removing("alice@devbox", from: usernames, costOnly: false)
        #expect(removedUsername.state.manualHosts == ["Alice@devbox"])
        #expect(removedUsername.changed)

        let raw = HostPreferences.State(
            manualTokens: [" DevBox ", "bad host", "-bad", "BAD HOST", "", "devbox", "mini", "a\tb"],
            costUsageHosts: ["DevBox"])
        let removed = try HostPreferences.removing("bad host", from: raw, costOnly: false)
        #expect(removed.state.manualTokens == [" DevBox ", "-bad", "", "devbox", "mini", "a\tb"])
        #expect(removed.changed)
        let removedDash = try HostPreferences.removing("-bad", from: removed.state, costOnly: false)
        #expect(removedDash.state.manualTokens == [" DevBox ", "", "devbox", "mini", "a\tb"])
        let removedTab = try HostPreferences.removing("a\tb", from: removedDash.state, costOnly: false)
        #expect(removedTab.state.manualTokens == [" DevBox ", "", "devbox", "mini"])
        #expect(!CodexBarCLI.configHostsEntries(removedTab.state).contains { !$0.valid })
    }

    @Test(arguments: ["", "one,two"])
    func `remove rejects ambiguous input`(host: String) {
        #expect(throws: (any Error).self) {
            _ = try HostPreferences.removing(host, from: HostPreferences.State(), costOnly: false)
        }
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
    func `list JSON shape and text keep check and mutation results`() throws {
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
                check: ConfigHostsCheckResult(ok: false, error: RemoteCodexCostError.invalidHost.errorDescription)),
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
        #expect(failed["error"] as? String == RemoteCodexCostError.invalidHost.errorDescription)

        #expect(hosts[2]["check"] == nil)
        let invalid = ConfigHostsEntry(host: "bad host", valid: false, costUsage: false, check: nil)
        #expect(CodexBarCLI.renderConfigHostEntry(invalid) == "bad host: invalid for spend")
        #expect(CodexBarCLI.renderConfigHostMutation(
            ConfigHostsMutationResult(host: "devbox", changed: false, costUsage: false, check: nil),
            action: .remove,
            costOnly: true) == "Host unchanged: devbox")
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
