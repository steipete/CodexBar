import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendDashboardIntegratedModelCoverageTests {
    @Test
    func `dashboard aggregation keeps every model from every cost capable integrated provider`() throws {
        let providers = ProviderDescriptorRegistry.all
            .filter(\.tokenCost.supportsTokenCost)
            .map(\.id)
        let inputs = providers.enumerated().map { index, provider in
            Self.input(provider: provider, costOffset: Double(index))
        }

        let group = try #require(SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: 365,
            now: Self.now,
            calendar: Self.calendar).groups.first)
        let expectedIDs = Set(providers.flatMap { provider in
            [
                "\(provider.rawValue):fixture-shared-model",
                "\(provider.rawValue):fixture-\(provider.rawValue)-primary",
            ]
        })

        #expect(Set(providers) == [
            .bedrock,
            .claude,
            .codex,
            .cursor,
            .mistral,
            .openai,
            .openrouter,
            .opencodego,
            .vertexai,
        ])
        #expect(Set(group.models.map(\.id)) == expectedIDs)
        #expect(group.models.count == providers.count * 2)
        #expect(group.models.allSatisfy { $0.totalTokens != nil && $0.totalCost != nil })
        #expect(group.modelHistoryCompleteness == .incomplete)
    }

    @Test
    func `OpenAI adapter keeps token only model rows without inventing model cost`() throws {
        let firstModel = OpenAIAPIUsageSnapshot.ModelBreakdown(
            name: "fixture-openai-primary",
            requests: 1,
            inputTokens: 6,
            cachedInputTokens: 0,
            outputTokens: 4,
            totalTokens: 10)
        let secondModel = OpenAIAPIUsageSnapshot.ModelBreakdown(
            name: "fixture-openai-secondary",
            requests: 1,
            inputTokens: 12,
            cachedInputTokens: 0,
            outputTokens: 8,
            totalTokens: 20)
        let usage = OpenAIAPIUsageSnapshot(
            daily: [
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2026-08-05",
                    startTime: Self.now,
                    endTime: Self.now.addingTimeInterval(86400),
                    costUSD: 3,
                    requests: 2,
                    inputTokens: 18,
                    cachedInputTokens: 0,
                    outputTokens: 12,
                    totalTokens: 30,
                    lineItems: [],
                    models: [firstModel, secondModel]),
            ],
            updatedAt: Self.now,
            historyDays: 365)
        let input = SpendDashboardModel.ProviderInput(
            provider: .openai,
            displayName: "OpenAI",
            snapshot: usage.toCostUsageTokenSnapshot())

        let group = try #require(SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 365,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(Set(group.models.map(\.modelName)) == [firstModel.name, secondModel.name])
        #expect(Set(group.models.compactMap(\.totalTokens)) == [10, 20])
        #expect(group.models.allSatisfy { $0.totalCost == nil })
        #expect(group.modelHistoryCompleteness == .incomplete)
    }

    private static func input(
        provider: UsageProvider,
        costOffset: Double) -> SpendDashboardModel.ProviderInput
    {
        let primaryCost = costOffset + 1
        let sharedCost = costOffset + 2
        let breakdowns = [
            CostUsageDailyReport.ModelBreakdown(
                modelName: "fixture-\(provider.rawValue)-primary",
                costUSD: primaryCost,
                totalTokens: 10),
            CostUsageDailyReport.ModelBreakdown(
                modelName: "fixture-shared-model",
                costUSD: sharedCost,
                totalTokens: 20),
        ]
        let entry = CostUsageDailyReport.Entry(
            date: "2026-08-04",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 30,
            costUSD: primaryCost + sharedCost,
            modelsUsed: breakdowns.map(\.modelName),
            modelBreakdowns: breakdowns)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 30,
            last30DaysCostUSD: primaryCost + sharedCost,
            currencyCode: "USD",
            historyDays: 365,
            daily: [entry],
            updatedAt: Self.now)
        return SpendDashboardModel.ProviderInput(
            provider: provider,
            displayName: "Fixture \(provider.rawValue)",
            snapshot: snapshot)
    }

    private static let now = Date(timeIntervalSince1970: 1_785_888_000) // 2026-08-05 00:00:00 UTC
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
