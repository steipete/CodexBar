import Foundation
import Testing
@testable import CodexBarCore

/// tcr (teamclaude-rs) prints claude-swap's list schema v1 from `tcr list --json`.
/// `tcr-list-v1.json` is tcr's own contract fixture (`tests/fixtures/cswap-list-v1.json`
/// in teamclaude-rs), with a synthetic model display label; these tests pin its wire shape.
struct ClaudeSwapTcrSourceTests {
    private func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "tcr-list-v1",
            withExtension: "json",
            subdirectory: "Fixtures/Providers/Claude"))
        return try Data(contentsOf: url)
    }

    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    private func makeFakeExecutable(_ script: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcr-source-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tcr")
        try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test
    func `tcr fixture parses unchanged as a pool with no active account and no switching`() throws {
        let list = try ClaudeSwapListParser.parse(self.fixture())
        #expect(list.activeAccountNumber == nil)
        #expect(list.supportsAccountSwitching == false)
        #expect(list.accounts.map(\.number) == [1, 2, 3, 4, 5, 6])
        #expect(list.accounts.allSatisfy { !$0.isActive })
        #expect(list.accounts.filter(\.isDisabled).map(\.number) == [3, 4])
    }

    @Test
    func `tcr rows project with their own identity and label and can never be activated`() throws {
        let now = try self.date("2026-01-01T00:00:00Z")
        let list = try ClaudeSwapListParser.parse(self.fixture())
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(from: list, source: .tcr, now: now)

        #expect(accounts.map(\.id) == (1...6).map { ProviderAccountIdentity(source: "tcr", opaqueID: String($0)) })
        #expect(accounts.allSatisfy { $0.sourceLabel == "tcr" && !$0.isActive && !$0.canActivate })
        #expect(accounts.allSatisfy { $0.snapshot?.identity?.loginMethod ?? "tcr" == "tcr" })

        let alice = try #require(accounts.first)
        #expect(alice.displayLabel == "alice@example.com")
        #expect(alice.snapshot?.primary?.usedPercent == 40)
        #expect(alice.snapshot?.secondary?.usedPercent == 60)
        #expect(alice.snapshot?.extraRateWindows?.map(\.window.usedPercent) == [10])
        #expect(alice.snapshot?.identity?.accountID == "tcr:1")

        #expect(accounts[2].displayLabel == "carol@example.com (disabled)")
        #expect(accounts[4].error == "Re-login required. Re-authenticate this account in tcr.")
    }

    @Test
    func `a tcr row without usageFetchedAt still parses and is stamped with the read time`() throws {
        // tcr omits usageFetchedAt when it does not know when the quota was read.
        let now = try self.date("2026-01-01T00:00:00Z")
        let list = try ClaudeSwapListParser.parse(self.fixture())
        #expect(try list.accounts[0].usageFetchedAt == (self.date("2025-12-31T23:00:00Z")))
        #expect(list.accounts[2].usageFetchedAt == nil)

        let accounts = ClaudeSwapAccountProjection.accountSnapshots(from: list, source: .tcr, now: now)
        #expect(try accounts[0].snapshot?.updatedAt == (self.date("2025-12-31T23:00:00Z")))
        #expect(accounts[2].snapshot?.primary?.usedPercent == 20)
        #expect(accounts[2].snapshot?.updatedAt == now)
    }

    @Test
    func `claude-swap remains the default source`() throws {
        let list = try ClaudeSwapListParser.parse(self.fixture())
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(from: list)
        #expect(accounts.first?.id == ProviderAccountIdentity(source: "claude-swap", opaqueID: "1"))
        #expect(accounts.first?.sourceLabel == "claude-swap")
        #expect(accounts[4].error == "Re-login required. Re-authenticate this account in claude-swap.")
    }

    @Test
    func `tcr source runs exactly tcr list --json`() async throws {
        let path = try self.makeFakeExecutable("""
        [ "$#" = 2 ] || exit 2
        [ "$1" = "list" ] || exit 2
        [ "$2" = "--json" ] || exit 2
        echo '{"schemaVersion": 1, "activeAccountNumber": null, "supportsAccountSwitching": false, "accounts": [
          {"number": 1, "email": "alice@example.com", "active": false, "usageStatus": "ok"}]}'
        """)

        let list = try await ClaudeSwapAccountReader.readAccountList(executablePath: path, source: .tcr)
        #expect(list.accounts.map(\.number) == [1])

        // The same executable refuses claude-swap's argv, so the source really chose the arguments.
        await #expect(throws: (any Error).self) {
            try await ClaudeSwapAccountReader.readAccountList(executablePath: path, source: .claudeSwap)
        }
    }

    @Test
    func `tcr version probe takes the last token`() async throws {
        let path = try self.makeFakeExecutable("""
        [ "$1" = "--version" ] || exit 2
        echo 'tcr 1.1.19'
        """)
        let version = await ClaudeSwapAccountReader.readVersion(executablePath: path, source: .tcr)
        #expect(version == "1.1.19")
    }

    @Test
    func `retained usage keeps the tcr identity and drops unknown sources`() throws {
        let now = try self.date("2026-01-01T00:00:00Z")
        let list = try ClaudeSwapListParser.parse(self.fixture())
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(from: list, source: .tcr, now: now)
        #expect(ClaudeSwapRetainedUsageStore.ownershipFingerprint(for: accounts[0]) != nil)

        let data = try #require(ClaudeSwapRetainedUsageStore.encode(accounts))
        let restored = ClaudeSwapRetainedUsageStore.decode(data)
        #expect(!restored.isEmpty)
        #expect(restored.allSatisfy { $0.id.source == "tcr" && $0.sourceLabel == "tcr" })

        var records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        records[0]["source"] = "some-future-tool"
        records[1].removeValue(forKey: "source")
        let edited = try JSONSerialization.data(withJSONObject: records)
        let mixed = ClaudeSwapRetainedUsageStore.decode(edited)
        #expect(mixed.count == records.count - 1)
        #expect(mixed.first?.id.source == "claude-swap")
    }

    @Test
    func `retained usage written before the source field still loads as claude-swap`() throws {
        // The exact record shape main writes: no `source` key at all.
        let fingerprint = try #require(ClaudeSwapRetainedUsageStore.fingerprint(
            email: "owner@example.com",
            slot: "2"))
        let window = RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let primary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(window))
        let legacy: [[String: Any]] = [[
            "opaqueID": "2",
            "accountFingerprint": fingerprint,
            "primary": primary,
            "updatedAt": 800_000_000.0,
        ]]
        let restored = try ClaudeSwapRetainedUsageStore.decode(JSONSerialization.data(withJSONObject: legacy))

        let account = try #require(restored.first)
        #expect(restored.count == 1)
        #expect(account.id == ProviderAccountIdentity(source: "claude-swap", opaqueID: "2"))
        #expect(account.sourceLabel == "claude-swap")
        #expect(account.snapshot?.primary?.usedPercent == 100)
        #expect(account.snapshot?.identity?.loginMethod == "claude-swap")
        #expect(ClaudeSwapRetainedUsageStore.ownershipFingerprint(for: account) == fingerprint)

        // A live claude-swap account still writes main's shape, so an older build can read it.
        let live = ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: "2"),
            provider: .claude,
            displayLabel: "owner@example.com",
            accountEmail: "owner@example.com",
            isActive: true,
            snapshot: UsageSnapshot(primary: window, secondary: nil, updatedAt: Date(timeIntervalSince1970: 1)),
            error: nil,
            sourceLabel: "claude-swap")
        let written = try #require(ClaudeSwapRetainedUsageStore.encode([live]))
        let records = try #require(JSONSerialization.jsonObject(with: written) as? [[String: Any]])
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(Set(record.keys) == ["opaqueID", "accountFingerprint", "primary", "updatedAt"])
        #expect(record["accountFingerprint"] as? String == fingerprint)
    }

    @Test
    func `a claude provider config written before claudeSwapSource keeps claude-swap`() throws {
        let legacy = Data(#"""
        {"id": "claude", "claudeSwapEnabled": true, "claudeSwapExecutablePath": "/opt/example/cswap"}
        """#.utf8)
        let config = try JSONDecoder().decode(ProviderConfig.self, from: legacy)
        #expect(config.claudeSwapSource == nil)
        #expect(config.resolvedClaudeSwapSource == .claudeSwap)
        #expect(config.claudeSwapEnabled == true)
        #expect(config.sanitizedClaudeSwapExecutablePath == "/opt/example/cswap")

        // Re-saving does not add the key, so the file stays readable by builds without tcr.
        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        #expect(encoded["claudeSwapSource"] == nil)
        #expect(encoded["claudeSwapEnabled"] as? Bool == true)
    }

    @Test
    func `config resolves the source and treats unknown values as claude-swap`() {
        var config = ProviderConfig(id: .claude)
        #expect(config.resolvedClaudeSwapSource == .claudeSwap)
        config.claudeSwapSource = "tcr"
        #expect(config.resolvedClaudeSwapSource == .tcr)
        config.claudeSwapSource = "something-else"
        #expect(config.resolvedClaudeSwapSource == .claudeSwap)
    }
}
