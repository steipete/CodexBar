import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ClaudeSwapLocalCostTests {
    @Test
    func `legacy adapter config loads without a profile mapping`() throws {
        let json = """
        {
          "id": "claude",
          "enabled": true,
          "source": "cli",
          "cookieSource": "off",
          "claudeSwapEnabled": true,
          "claudeSwapExecutablePath": "/fixture/legacy-adapter",
          "claudeSwapShowSingleAccount": true
        }
        """
        let legacy = try JSONDecoder().decode(ProviderConfig.self, from: Data(json.utf8))
        let roundTrip = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(legacy))
        #expect(roundTrip.claudeSwapCostProfiles == nil)
        #expect(roundTrip.enabled == true)
        #expect(roundTrip.source == .cli)
        #expect(roundTrip.cookieSource == .off)
        #expect(roundTrip.claudeSwapEnabled == true)
        #expect(roundTrip.claudeSwapExecutablePath == "/fixture/legacy-adapter")
        #expect(roundTrip.claudeSwapShowSingleAccount == true)
    }

    @Test
    func `profile costs follow the account identity across switches and slot reuse`() async throws {
        let fixture = try CostUsageTestEnvironment()
        defer { fixture.cleanup() }
        let now = Date()
        let personal = fixture.root.appendingPathComponent("personal")
        let work = fixture.root.appendingPathComponent("work")
        let ambient = fixture.root.appendingPathComponent("ambient")
        for (index, root) in [personal, work, ambient].enumerated() {
            let project = root.appendingPathComponent("projects/sample")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let row: [String: Any] = [
                "type": "assistant", "timestamp": fixture.isoString(for: now), "requestId": "request-\(index)",
                "message": [
                    "id": "message-\(index)",
                    "model": "claude-sonnet-4-20250514",
                    "usage": ["input_tokens": (index + 1) * 100, "output_tokens": 10],
                ],
            ]
            try fixture.jsonl([row]).write(
                to: project.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        }
        #expect(try ModelsDevCache.save(
            catalog: CostUsageClaudeResolverTests.simpleCatalog(["claude-sonnet-4-20250514": 3]),
            fetchedAt: now,
            cacheRoot: fixture.cacheRoot))
        let settings = testSettingsStore(
            suiteName: "ClaudeSwapLocalCostTests",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }))
        enableTestProviders([.claude], settings: settings)
        settings.costUsageEnabled = true
        settings.claudeSwapEnabled = true
        settings.claudeSwapExecutablePath = "/fixture/unused-adapter"
        let fixtureEmail = "account@example.com"
        let organization = "00000000-0000-0000-0000-000000000001"
        settings.updateProviderConfig(provider: .claude) {
            $0.claudeSwapCostProfiles = [
                .init(email: fixtureEmail.uppercased(), configDirectory: personal.path),
                .init(email: fixtureEmail, organizationUuid: organization, configDirectory: work.path),
            ]
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(scannerOptions: .init(
                claudeProjectsRoots: [ambient.appendingPathComponent("projects")],
                cacheRoot: fixture.cacheRoot)),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: ["HOME": fixture.root.path],
            widgetSnapshotURL: fixture.root.appendingPathComponent("widget.json"),
            widgetTimelineReloader: {})

        func account(
            _ number: Int,
            organizationUuid: String = "",
            active: Bool = false,
            email: String? = nil) -> ClaudeSwapAccountRow
        {
            ClaudeSwapAccountRow(
                number: number,
                email: email ?? fixtureEmail,
                organizationUuid: organizationUuid,
                isActive: active,
                usageStatus: .ok,
                fiveHour: nil,
                sevenDay: nil)
        }

        func publish(_ rows: [ClaudeSwapAccountRow], active: Int) {
            store.claudeSwapAccountSnapshots = ClaudeSwapAccountProjection.accountSnapshots(
                from: ClaudeSwapAccountList(activeAccountNumber: active, accounts: rows))
        }

        publish([account(1, active: true), account(2, organizationUuid: organization)], active: 1)
        store.scheduleClaudeSwapLocalCostRefresh(now: now)
        await store.claudeSwapLocalCostState.task?.value
        #expect(store.claudeSwapAccountSnapshots.map {
            store.claudeSwapLocalTokenCost(for: $0)?.last30DaysTokens
        } == [110, 210])
        for (account, tokens) in zip(store.claudeSwapAccountSnapshots, [110, 210]) {
            let context = ClaudeSwapAccountMenuDisplay.cardContext(
                for: account,
                planLabel: nil,
                adapterError: nil,
                switchError: nil,
                localTokenCost: store.claudeSwapLocalTokenCost(for: account))
            let estimate = store.menuCardInput(for: .claude, context: context).tokenSnapshot
            #expect(estimate?.last30DaysTokens == tokens)
            #expect(estimate?.last30DaysCostUSD != nil)
        }

        publish([account(2), account(1, organizationUuid: organization, active: true)], active: 1)
        #expect(store.claudeSwapAccountSnapshots.map {
            store.claudeSwapLocalTokenCost(for: $0)?.last30DaysTokens
        } == [210, 110])

        publish([account(2), account(1, active: true, email: "replacement@example.com")], active: 1)
        store.scheduleClaudeSwapLocalCostRefresh(now: now)
        await store.claudeSwapLocalCostState.task?.value
        #expect(store.claudeSwapAccountSnapshots.map {
            store.claudeSwapLocalTokenCost(for: $0)?.last30DaysTokens
        } == [nil, 110])

        let mappedAccount = store.claudeSwapAccountSnapshots[1]
        for (period, label) in [(CostReportingPeriod.monthToDate, "Month to date"), (.allTime, "All")] {
            settings.costReportingPeriod = period
            #expect(store.claudeSwapLocalTokenCost(for: mappedAccount) == nil)
            store.scheduleClaudeSwapLocalCostRefresh(now: now)
            await store.claudeSwapLocalCostState.task?.value
            let estimate = try #require(store.claudeSwapLocalTokenCost(for: mappedAccount))
            #expect(estimate.last30DaysTokens == 110)
            #expect(estimate.reportingPeriod == period)
            #expect(estimate.historyLabel == label)
        }

        try FileManager.default.removeItem(at: personal)
        store.scheduleClaudeSwapLocalCostRefresh(force: true, now: now)
        await store.claudeSwapLocalCostState.task?.value
        #expect(store.claudeSwapAccountSnapshots.allSatisfy { store.claudeSwapLocalTokenCost(for: $0) == nil })
    }
}
