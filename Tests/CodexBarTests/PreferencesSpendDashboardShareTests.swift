import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
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
                    SpendDashboardModel.ProviderRow(
                        id: "codex:work",
                        rank: 2,
                        provider: .codex,
                        displayName: "Codex · Work",
                        totalTokens: 100,
                        totalCost: 3,
                        coveredDayCount: 30),
                ],
                models: [],
                dailyPoints: [],
                totalTokens: 300,
                totalCost: 7,
                coveredDayCount: 30,
                chartDomain: date...date,
                modelHistoryCompleteness: .complete),
        ])
        let trackedSources = [
            Self.source(
                id: "codex:personal",
                provider: .codex,
                providerName: "Codex",
                state: .connected,
                contributesCostHistory: true),
            Self.source(
                id: "codex:work",
                provider: .codex,
                providerName: "Codex",
                state: .configured,
                contributesCostHistory: true),
            Self.source(
                id: "openrouter:current",
                provider: .openrouter,
                providerName: "OpenRouter",
                state: .awaitingUsage,
                contributesCostHistory: true),
            Self.source(
                id: "gemini:current",
                provider: .gemini,
                providerName: "Gemini",
                state: .needsAttention,
                contributesCostHistory: false),
        ]

        let payload = try #require(SpendDashboardPane.makeSharePayload(
            model: model,
            subscriptionNames: [:],
            trackedSources: trackedSources))

        #expect(payload.providers.map(\.provider) == [.codex, .openrouter, .gemini])
        #expect(payload.providers.map(\.estimatedCost) == [7, nil, nil])
        #expect(payload.spendReportingProviderCount == 1)
        let allCurrenciesArePartial = payload.currencies.allSatisfy(\.isPartial)
        #expect(allCurrenciesArePartial)
        #expect(payload.totalTokensIsPartial)
        #expect(ShareStatsFormatting.text(payload).contains("1/3 connected services report spend"))
    }

    @Test
    func `missing tracked account keeps settings share partial`() throws {
        let model = SpendDashboardModel(requestedDays: 30, groups: [
            Self.group(currencyCode: "USD", providers: [Self.row(id: "codex:personal", tokens: 200, cost: 4)]),
        ])
        let payload = try #require(SpendDashboardPane.makeSharePayload(
            model: model,
            subscriptionNames: [:],
            trackedSources: [
                Self.source(
                    id: "codex:personal",
                    provider: .codex,
                    providerName: "Codex",
                    state: .connected,
                    contributesCostHistory: true),
                Self.source(
                    id: "codex:work",
                    provider: .codex,
                    providerName: "Codex",
                    state: .configured,
                    contributesCostHistory: true),
            ]))

        #expect(payload.providers.first?.estimatedCost == 4)
        let allCurrenciesArePartial = payload.currencies.allSatisfy(\.isPartial)
        #expect(allCurrenciesArePartial)
        #expect(payload.totalTokensIsPartial)
    }

    @Test
    func `provider accounts in unlike currencies never merge spend`() throws {
        let model = SpendDashboardModel(requestedDays: 30, groups: [
            Self.group(currencyCode: "USD", providers: [Self.row(id: "codex:personal", tokens: 200, cost: 4)]),
            Self.group(currencyCode: "EUR", providers: [Self.row(id: "codex:work", tokens: 100, cost: 3)]),
        ])
        let trackedSources = ["codex:personal", "codex:work"].map {
            Self.source(
                id: $0,
                provider: .codex,
                providerName: "Codex",
                state: .connected,
                contributesCostHistory: true)
        }
        let payload = try #require(SpendDashboardPane.makeSharePayload(
            model: model,
            subscriptionNames: [:],
            trackedSources: trackedSources))

        #expect(payload.providers.first?.estimatedCost == nil)
        let allCurrenciesArePartial = payload.currencies.allSatisfy(\.isPartial)
        #expect(allCurrenciesArePartial)
    }

    @Test
    func `provider family overflow fails closed`() throws {
        let model = SpendDashboardModel(requestedDays: 30, groups: [
            Self.group(currencyCode: "USD", providers: [
                Self.row(id: "codex:personal", tokens: Int.max, cost: Double.greatestFiniteMagnitude),
                Self.row(id: "codex:work", tokens: 1, cost: Double.greatestFiniteMagnitude),
            ]),
        ])
        let trackedSources = ["codex:personal", "codex:work"].map {
            Self.source(
                id: $0,
                provider: .codex,
                providerName: "Codex",
                state: .connected,
                contributesCostHistory: true)
        }
        let payload = try #require(SpendDashboardPane.makeSharePayload(
            model: model,
            subscriptionNames: [:],
            trackedSources: trackedSources))

        #expect(payload.providers.first?.totalTokens == nil)
        #expect(payload.providers.first?.estimatedCost == nil)
        let allCurrenciesArePartial = payload.currencies.allSatisfy(\.isPartial)
        #expect(allCurrenciesArePartial)
        #expect(payload.totalTokensIsPartial)
    }

    @Test
    func `mismatched account identity is excluded and marks share partial`() throws {
        let model = SpendDashboardModel(requestedDays: 30, groups: [
            Self.group(currencyCode: "USD", providers: [
                Self.row(id: "codex:a", tokens: 200, cost: 4),
                Self.row(id: "codex:c", tokens: 900, cost: 9),
            ]),
        ])
        let payload = try #require(SpendDashboardPane.makeSharePayload(
            model: model,
            subscriptionNames: [:],
            trackedSources: Self.codexSources(ids: ["codex:a", "codex:b"])))

        #expect(payload.providers.first?.estimatedCost == 4)
        #expect(payload.providers.first?.totalTokens == 200)
        #expect(payload.currencies.first?.estimatedCost == 4)
        let allCurrenciesArePartial = payload.currencies.allSatisfy(\.isPartial)
        #expect(allCurrenciesArePartial)
        #expect(payload.totalTokensIsPartial)
        #expect(payload.topModels.isEmpty)
    }

    @Test
    func `extra stale account row is excluded and marks share partial`() throws {
        let model = SpendDashboardModel(requestedDays: 30, groups: [
            Self.group(currencyCode: "USD", providers: [
                Self.row(id: "codex:a", tokens: 200, cost: 4),
                Self.row(id: "codex:b", tokens: 100, cost: 3),
                Self.row(id: "codex:c", tokens: 900, cost: 9),
            ]),
        ])
        let payload = try #require(SpendDashboardPane.makeSharePayload(
            model: model,
            subscriptionNames: [:],
            trackedSources: Self.codexSources(ids: ["codex:a", "codex:b"])))

        #expect(payload.providers.first?.estimatedCost == 7)
        #expect(payload.providers.first?.totalTokens == 300)
        #expect(payload.currencies.first?.estimatedCost == 7)
        let allCurrenciesArePartial = payload.currencies.allSatisfy(\.isPartial)
        #expect(allCurrenciesArePartial)
        #expect(payload.totalTokensIsPartial)
    }

    @Test
    func `stale provider family is excluded from top models`() throws {
        let date = Date(timeIntervalSince1970: 1_785_974_400)
        let group = SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: [
                Self.row(id: "codex:a", tokens: 200, cost: 4),
                SpendDashboardModel.ProviderRow(
                    id: "openrouter",
                    rank: 1,
                    provider: .openrouter,
                    displayName: "OpenRouter",
                    totalTokens: 900,
                    totalCost: 9,
                    coveredDayCount: 30),
            ],
            models: [
                SpendDashboardModel.ModelRow(
                    rank: 1,
                    provider: .openrouter,
                    providerName: "OpenRouter",
                    modelName: "anthropic/claude-sonnet-4",
                    totalTokens: 900,
                    totalCost: 9),
            ],
            dailyPoints: [],
            totalTokens: 1100,
            totalCost: 13,
            coveredDayCount: 30,
            chartDomain: date...date,
            modelHistoryCompleteness: .complete)
        let model = SpendDashboardModel(requestedDays: 30, groups: [group])
        let payload = try #require(SpendDashboardPane.makeSharePayload(
            model: model,
            subscriptionNames: [:],
            trackedSources: Self.codexSources(ids: ["codex:a"])))

        #expect(payload.providers.map(\.provider) == [.codex])
        #expect(payload.currencies.compactMap(\.estimatedCost) == [4])
        #expect(payload.totalTokens == 200)
        #expect(payload.totalTokensIsPartial)
        #expect(payload.topModels.isEmpty)
    }

    private static func source(
        id: String,
        provider: UsageProvider,
        providerName: String,
        state: SpendDashboardTrackedSource.State,
        contributesCostHistory: Bool) -> SpendDashboardTrackedSource
    {
        SpendDashboardTrackedSource(
            id: id,
            provider: provider,
            providerName: providerName,
            accountName: nil,
            state: state,
            supportsCostHistory: contributesCostHistory,
            contributesCostHistory: contributesCostHistory)
    }

    private static func row(id: String, tokens: Int, cost: Double) -> SpendDashboardModel.ProviderRow {
        SpendDashboardModel.ProviderRow(
            id: id,
            rank: 1,
            provider: .codex,
            displayName: "Codex",
            totalTokens: tokens,
            totalCost: cost,
            coveredDayCount: 30)
    }

    private static func codexSources(ids: [String]) -> [SpendDashboardTrackedSource] {
        ids.map {
            Self.source(
                id: $0,
                provider: .codex,
                providerName: "Codex",
                state: .connected,
                contributesCostHistory: true)
        }
    }

    private static func group(
        currencyCode: String,
        providers: [SpendDashboardModel.ProviderRow]) -> SpendDashboardModel.CurrencyGroup
    {
        let date = Date(timeIntervalSince1970: 1_785_974_400)
        return SpendDashboardModel.CurrencyGroup(
            currencyCode: currencyCode,
            providers: providers,
            models: [],
            dailyPoints: [],
            totalTokens: nil,
            totalCost: nil,
            coveredDayCount: 30,
            chartDomain: date...date,
            modelHistoryCompleteness: .incomplete)
    }
}
