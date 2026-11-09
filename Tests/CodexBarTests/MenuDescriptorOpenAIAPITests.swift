import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct MenuDescriptorOpenAIAPITests {
    @Test
    func `openai api admin usage appears in descriptor summaries`() throws {
        let suite = "MenuDescriptorOpenAIAPITests-admin-summary"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = try Self.localNoon(year: 2023, month: 11, day: 17)
        let firstDay = try Self.localNoon(year: 2023, month: 11, day: 13)
        let secondDay = try Self.localNoon(year: 2023, month: 11, day: 14)
        let usage = OpenAIAPIUsageSnapshot(
            daily: [
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2023-11-13",
                    startTime: firstDay,
                    endTime: firstDay.addingTimeInterval(86400),
                    costUSD: 5,
                    requests: 8,
                    inputTokens: 100,
                    cachedInputTokens: 0,
                    outputTokens: 50,
                    totalTokens: 150,
                    lineItems: [],
                    models: [
                        OpenAIAPIUsageSnapshot.ModelBreakdown(
                            name: "gpt-5.2",
                            requests: 8,
                            inputTokens: 100,
                            cachedInputTokens: 0,
                            outputTokens: 50,
                            totalTokens: 150),
                    ]),
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2023-11-14",
                    startTime: secondDay,
                    endTime: secondDay.addingTimeInterval(86400),
                    costUSD: 12.5,
                    requests: 40,
                    inputTokens: 1000,
                    cachedInputTokens: 250,
                    outputTokens: 500,
                    totalTokens: 1500,
                    lineItems: [],
                    models: [
                        OpenAIAPIUsageSnapshot.ModelBreakdown(
                            name: "gpt-5.2-codex",
                            requests: 40,
                            inputTokens: 1000,
                            cachedInputTokens: 250,
                            outputTokens: 500,
                            totalTokens: 1500),
                    ]),
            ],
            updatedAt: now)
        store._setSnapshotForTesting(usage.toUsageSnapshot(), provider: .openai)

        let descriptor = MenuDescriptor.build(
            provider: .openai,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        let lines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(lines.contains("Today: $0.00 · 0 tokens"))
        #expect(lines.contains("7d: $17.50 · 48 requests"))
        #expect(lines.contains("30d: $17.50 · 48 requests"))
        #expect(lines.contains("Top model: gpt-5.2-codex"))
        #expect(!lines.contains("No usage yet"))
        let presentation = OpenAIAPIProviderDescriptor.descriptor.presentation
        #expect(presentation.cost(snapshot: usage.toUsageSnapshot()).menuCardStyle == .apiSpend)
        #expect(MenuBarLayoutBalanceResolver.balance(provider: .openai, snapshot: usage.toUsageSnapshot()) == nil)
    }

    @Test
    func `openai platform credits show the credit lane and prepaid balance`() throws {
        let settings = testSettingsStore(
            suiteName: "MenuDescriptorOpenAIAPITests-platform-credits",
            userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let body = """
        {"total_granted":124,"total_used":0.834548,"total_available":123.165452,"grants":{"data":[
          {"id":"chatgpt_api_credits_promo_fixture","grant_amount":124,"used_amount":0.834548,
           "effective_at":1794047545,"expires_at":1795712905,"is_scheduled":false}]}}
        """
        let snapshot = try OpenAIPlatformCreditGrants.snapshot(
            from: Data(body.utf8),
            now: Date(timeIntervalSince1970: 1_794_139_200))
        store._setSnapshotForTesting(snapshot, provider: .openai)

        let lines = MenuDescriptor.build(
            provider: .openai,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false).sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(lines.contains { $0.hasPrefix("API credit: ") })
        let cost = OpenAIAPIProviderDescriptor.descriptor.presentation.cost(snapshot: snapshot)
        #expect(cost.menuCardStyle == .prepaidCredits && !cost.showsGenericFallback)
        #expect(MenuBarLayoutBalanceResolver.balance(provider: .openai, snapshot: snapshot) == "$123.17")
    }

    private static func localNoon(year: Int, month: Int, day: Int) throws -> Date {
        try #require(Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
    }
}
