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
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let usage = OpenAIAPIUsageSnapshot(
            daily: [
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2023-11-13",
                    startTime: now.addingTimeInterval(-86400),
                    endTime: now,
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
                    startTime: now,
                    endTime: now.addingTimeInterval(86400),
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

        #expect(lines.contains("Today: $12.50 · 1.5K tokens"))
        #expect(lines.contains("7d: $17.50 · 48 requests"))
        #expect(lines.contains("30d: $17.50 · 48 requests"))
        #expect(lines.contains("Top model: gpt-5.2-codex"))
        #expect(!lines.contains("No usage yet"))
    }
}
