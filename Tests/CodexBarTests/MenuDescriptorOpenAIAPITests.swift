import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

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
    }

    private static func localNoon(year: Int, month: Int, day: Int) throws -> Date {
        try #require(Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
    }
}
