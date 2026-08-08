import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct PreferencesSpendDashboardShareTests {
    @Test
    func `settings share includes every tracked provider once even without cost history`() throws {
        let date = Date(timeIntervalSince1970: 1_785_974_400)
        let model = SpendDashboardModel(requestedDays: 30, groups: [
            SpendDashboardModel.CurrencyGroup(
                currencyCode: "USD",
                providers: [
                    SpendDashboardModel.ProviderRow(
                        id: "codex:personal",
                        rank: 1,
                        provider: .codex,
                        displayName: "Codex · Personal",
                        totalTokens: 200,
                        totalCost: 4,
                        coveredDayCount: 30),
                ],
                models: [],
                dailyPoints: [],
                totalTokens: 200,
                totalCost: 4,
                coveredDayCount: 30,
                chartDomain: date...date,
                modelHistoryCompleteness: .complete),
        ])
        let trackedSources = [
            Self.source(
                id: "codex:personal",
                provider: .codex,
                providerName: "Codex",
                accountName: "Personal",
                state: .connected,
                contributesCostHistory: true),
            Self.source(
                id: "codex:work",
                provider: .codex,
                providerName: "Codex",
                accountName: "Work",
                state: .configured,
                contributesCostHistory: true),
            Self.source(
                id: "openrouter:current",
                provider: .openrouter,
                providerName: "OpenRouter",
                accountName: nil,
                state: .awaitingUsage,
                contributesCostHistory: true),
            Self.source(
                id: "gemini:current",
                provider: .gemini,
                providerName: "Gemini",
                accountName: nil,
                state: .needsAttention,
                contributesCostHistory: false),
        ]

        let payload = try #require(SpendDashboardPane.makeSharePayload(
            model: model,
            subscriptionNames: [:],
            trackedSources: trackedSources))

        #expect(payload.providers.map(\.provider) == [.codex, .openrouter, .gemini])
        #expect(payload.providers.map(\.estimatedCost) == [4, nil, nil])
        #expect(payload.spendReportingProviderCount == 1)
        #expect(payload.currencies.allSatisfy(\.isPartial))
        #expect(payload.totalTokensIsPartial)
        #expect(ShareStatsFormatting.text(payload).contains("1/3 connected services report spend"))
    }

    private static func source(
        id: String,
        provider: UsageProvider,
        providerName: String,
        accountName: String?,
        state: SpendDashboardTrackedSource.State,
        contributesCostHistory: Bool) -> SpendDashboardTrackedSource
    {
        SpendDashboardTrackedSource(
            id: id,
            provider: provider,
            providerName: providerName,
            accountName: accountName,
            state: state,
            supportsCostHistory: contributesCostHistory,
            contributesCostHistory: contributesCostHistory)
    }
}
