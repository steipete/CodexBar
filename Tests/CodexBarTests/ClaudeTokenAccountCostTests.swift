import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ClaudeTokenAccountCostTests {
    @Test
    func `legacy accounts decode without a directory and mapped accounts retain it`() throws {
        let legacy: [String: Any] = [
            "id": UUID().uuidString, "label": "Personal", "token": "fixture-token", "addedAt": 1,
        ]
        for directory in [nil, "/fixtures/claude-personal"] as [String?] {
            var json = legacy
            json["claudeConfigDirectory"] = directory
            let account = try JSONDecoder().decode(
                ProviderTokenAccount.self, from: JSONSerialization.data(withJSONObject: json))
            let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(account))
                as? [String: Any])
            #expect(encoded["claudeConfigDirectory"] as? String == directory)
        }
    }

    @Test
    func `mapped costs follow the active directory and never fall back to other history`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = Date()
        let first = env.root.appendingPathComponent("personal")
        let second = env.root.appendingPathComponent("work")
        let roots = [first, second, env.root.appendingPathComponent("ambient")]
        for (index, root) in roots.enumerated() {
            let projects = root.appendingPathComponent("projects/sample")
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            let row: [String: Any] = [
                "type": "assistant", "timestamp": env.isoString(for: now), "requestId": "request-\(index)",
                "message": [
                    "id": "message-\(index)",
                    "model": "claude-sonnet-4-20250514",
                    "usage": ["input_tokens": (index + 1) * 100, "output_tokens": 10],
                ],
            ]
            try env.jsonl([row]).write(
                to: projects.appendingPathComponent("session.jsonl"),
                atomically: true,
                encoding: .utf8)
        }
        #expect(try ModelsDevCache.save(
            catalog: CostUsageClaudeResolverTests.simpleCatalog(["claude-sonnet-4-20250514": 3]),
            fetchedAt: now,
            cacheRoot: env.cacheRoot))
        let settings = testSettingsStore(
            suiteName: "ClaudeTokenAccountCostTests",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }))
        enableTestProviders([.claude], settings: settings)
        settings.costUsageEnabled = true
        settings.addTokenAccount(
            provider: .claude,
            label: "Personal",
            token: "fixture-personal",
            claudeConfigDirectory: first.path)
        let firstAccount = try #require(settings.selectedTokenAccount(for: .claude))
        settings.addTokenAccount(
            provider: .claude,
            label: "Work",
            token: "fixture-work",
            claudeConfigDirectory: second.path)
        settings.addTokenAccount(provider: .claude, label: "Combined", token: "fixture-combined")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(scannerOptions: .init(
                claudeProjectsRoots: roots.map { $0.appendingPathComponent("projects") },
                cacheRoot: env.cacheRoot)),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: ["HOME": env.root.path],
            widgetSnapshotURL: env.root.appendingPathComponent("widget.json"),
            widgetTimelineReloader: {})

        // Reuse the same scanner cache across account changes, including returning to an earlier scope.
        for (index, tokens) in [(0, 110), (1, 210), (0, 110), (2, 630)] {
            settings.setActiveTokenAccountIndex(index, for: .claude)
            #expect(store.shouldIncludePiSessionsInTokenSnapshot(for: .claude) == (index == 2))
            #expect(store.tokenSnapshot(for: .claude) == nil)
            let result = try await store.loadTokenUsageSnapshot(
                provider: .claude,
                force: false,
                now: now,
                codexHomePath: nil,
                historyDays: 30,
                includePiSessions: false)
            #expect(result.snapshot.last30DaysTokens == tokens)
            #expect(result.snapshot.last30DaysCostUSD != nil)
            store.publishTokenSnapshot(result.snapshot, for: .claude)
        }
        #expect(store.tokenCostScope(for: .claude).signature == "claude")
        settings.setActiveTokenAccountIndex(0, for: .claude)
        #expect(store.tokenSnapshot(for: .claude) == nil)
        let dashboard = try await store.loadTokenUsageSnapshot(
            provider: .claude,
            force: false,
            now: now,
            codexHomePath: nil,
            historyDays: SpendDashboardSource.scanDays,
            includePiSessions: false,
            reportContext: .spendDashboard)
        #expect(dashboard.snapshot.last30DaysTokens == 110)
        settings.updateTokenAccount(
            provider: .claude,
            accountID: firstAccount.id,
            label: "Renamed",
            token: "fixture-refreshed")
        #expect(settings.selectedTokenAccount(for: .claude)?.claudeConfigDirectory == first.path)
        #expect(firstAccount.withModelRateLimits(nil).claudeConfigDirectory == first.path)
        #expect(firstAccount.sanitizedForDump().claudeConfigDirectory == first.path)

        // A deleted history directory clears a previously successful estimate on the first refresh.
        await store.refreshTokenUsage(.claude, force: true)
        #expect(store.tokenSnapshot(for: .claude)?.last30DaysTokens == 110)
        try FileManager.default.removeItem(at: first)
        await store.refreshTokenUsage(.claude, force: true)
        #expect(store.tokenSnapshot(for: .claude) == nil)
        #expect(store.tokenError(for: .claude) != nil)

        settings.updateTokenAccount(
            provider: .claude,
            accountID: firstAccount.id,
            claudeConfigDirectory: .some(nil))
        #expect(store.claudeTokenCostConfigDirectory == nil)
        #expect(store.tokenCostScope(for: .claude).signature == "claude")
    }

    @Test
    func `account roots exclude configured ambient and swap roots`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let swap = env.root.appendingPathComponent(".claude-swap-backup/sessions/1-personal/projects")
        try FileManager.default.createDirectory(at: swap, withIntermediateDirectories: true)
        let account = env.root.appendingPathComponent("account, directory")
        let ambient = env.root.appendingPathComponent("ambient/projects")
        let environment = ["HOME": env.root.path, "CLAUDE_CONFIG_DIR": ambient.deletingLastPathComponent().path]
        #expect(ClaudeConfigPaths.costProjectsRoots(
            accountConfigDirectory: account.path, environment: environment).map(\.path) ==
            [account.appendingPathComponent("projects").path])
        #expect(ClaudeConfigPaths.costProjectsRoots(environment: environment).map(\.path) == [ambient.path, swap.path])
        #expect(ClaudeConfigPaths.costProjectsRoots(accountConfigDirectory: nil, environment: environment) ==
            ClaudeConfigPaths.costProjectsRoots(environment: environment))
    }
}
