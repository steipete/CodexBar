import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// A partial or partly unpriced scan must stay marked as a floor everywhere it is shown or exported.
/// The header used to say "partial estimate" while the subscription row and the exported JSON
/// presented the same totals as exact values.
struct SpendDashboardLowerBoundPropagationTests {
    @Test
    func `metric text marks lower bound cost and tokens`() {
        let both = spendDashboardMetricText(
            cost: 74.15,
            tokens: 431_000_000,
            currencyCode: "USD",
            costIsLowerBound: true,
            tokensAreLowerBound: true)
        #expect(both.contains("≥"))
        #expect(both.components(separatedBy: "≥").count == 3)

        let costOnly = spendDashboardMetricText(
            cost: 74.15,
            tokens: 431_000_000,
            currencyCode: "USD",
            costIsLowerBound: true,
            tokensAreLowerBound: false)
        #expect(costOnly.components(separatedBy: "≥").count == 2)
    }

    @Test
    func `exact totals keep no lower bound marker`() {
        let text = spendDashboardMetricText(cost: 12, tokens: 900, currencyCode: "USD")
        #expect(!text.contains("≥"))
    }

    @Test
    func `a partial Antigravity scan exports its lower bound status`() throws {
        let model = try Self.partialModel()
        let group = try #require(
            SpendDashboardExportPayload.make(model: model, hiddenSourceIDs: []).groups.first)

        #expect(group.costIsLowerBound)
        #expect(group.tokensAreLowerBound)
        let provider = try #require(group.providers.first)
        #expect(provider.costIsLowerBound)
        #expect(provider.tokensAreLowerBound)
        // The flags are only meaningful if a subtotal actually reached the export.
        #expect(provider.totalCost == 2)
        #expect(provider.totalTokens == 100)
    }

    @Test
    func `a complete scan exports without lower bound status`() throws {
        let model = try Self.completeModel()
        let group = try #require(
            SpendDashboardExportPayload.make(model: model, hiddenSourceIDs: []).groups.first)

        #expect(!group.costIsLowerBound)
        #expect(!group.tokensAreLowerBound)
        let provider = try #require(group.providers.first)
        #expect(!provider.costIsLowerBound)
        #expect(!provider.tokensAreLowerBound)
        #expect(provider.totalCost == 2)
        #expect(provider.totalTokens == 100)
    }

    @Test
    func `an all priced partial scan is still exported as a floor`() throws {
        // Every request has a price, so only the truncated scan makes the total a lower bound.
        let model = try Self.partialModel(unpricedRequestCount: 0)
        let group = try #require(
            SpendDashboardExportPayload.make(model: model, hiddenSourceIDs: []).groups.first)
        let provider = try #require(group.providers.first)

        #expect(provider.costIsLowerBound)
        #expect(provider.tokensAreLowerBound)
        #expect(provider.totalCost == 2)
        #expect(provider.totalTokens == 100)
    }

    @Test(arguments: [false, true])
    func `daily token and request counts retain scan completeness`(partial: Bool) throws {
        let model = try Self.model(historyScanIsPartial: partial, unpricedRequestCount: 0)
        let group = try #require(model.groups.first)
        let day = try #require(group.dailySummaries.first { $0.totalTokens == 100 })
        #expect(day.hasPartialCounts == partial)
        #expect(day.providers.first?.countsAreLowerBound == partial)
        #expect(day.totalTokens == 100)
        #expect(day.requestCount == (partial ? nil : 1))
        if partial {
            #expect(group.dailySummaries.flatMap(\.providers).allSatisfy { !$0.isKnownIdle })
        }
    }

    @Test(arguments: [false, true], [0, 1])
    func `provider hierarchy distinguishes scan floors from missing prices`(
        partial: Bool, unpricedRequests: Int) throws
    {
        let model = try Self.model(historyScanIsPartial: partial, unpricedRequestCount: unpricedRequests)
        let group = try #require(model.groups.first)
        let provider = try #require(spendDashboardProviderBreakdowns(group).first)
        let costIsLowerBound = partial || unpricedRequests > 0
        #expect(provider.costIsLowerBound == costIsLowerBound)
        #expect(provider.tokensAreLowerBound == partial)
        #expect(provider.hasPartialCost == costIsLowerBound)
        #expect(provider.hasPartialTokens == partial)
        #expect(provider.subscriptions.first?.costIsLowerBound == costIsLowerBound)
        #expect(provider.subscriptions.first?.tokensAreLowerBound == partial)
        if partial {
            #expect(provider.hasPartialModelHistory)
            #expect(group.modelHistoryCompleteness == .incomplete)
        }
        let text = spendDashboardBreakdownMetricText(
            cost: provider.totalCost,
            tokens: provider.totalTokens,
            currencyCode: group.currencyCode,
            hasPartialCost: provider.hasPartialCost,
            hasPartialTokens: provider.hasPartialTokens,
            incompleteRequestCount: provider.incompleteRequestCount,
            costIsLowerBound: provider.costIsLowerBound,
            tokensAreLowerBound: provider.tokensAreLowerBound)
        #expect(!text.contains("~"))
        #expect(text.filter { $0 == "≥" }.count == (costIsLowerBound ? 1 : 0) + (partial ? 1 : 0))
        let exported = try #require(SpendDashboardExportPayload.make(model: model, hiddenSourceIDs: []).groups.first)
        #expect(exported.costIsLowerBound == costIsLowerBound)
        #expect(exported.tokensAreLowerBound == partial)
    }

    private static func partialModel(unpricedRequestCount: Int = 1) throws -> SpendDashboardModel {
        try self.model(historyScanIsPartial: true, unpricedRequestCount: unpricedRequestCount)
    }

    private static func completeModel() throws -> SpendDashboardModel {
        try self.model(historyScanIsPartial: false, unpricedRequestCount: 0)
    }

    private static func model(
        historyScanIsPartial: Bool,
        unpricedRequestCount: Int) throws -> SpendDashboardModel
    {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-15",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 100,
            requestCount: 1,
            costUSD: 2,
            modelsUsed: nil,
            modelBreakdowns: [.init(modelName: "fixture-priced-model", costUSD: 2, totalTokens: 100)],
            unpricedRequestCount: unpricedRequestCount,
            estimatedRequestCount: 1)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 100,
            last30DaysCostUSD: 2,
            historyDays: 30,
            historyCoverageIsEstablished: !historyScanIsPartial,
            historyScanIsPartial: historyScanIsPartial,
            costProvenance: .listPriceEstimate,
            daily: [entry],
            updatedAt: Self.now)
        return SpendDashboardModel.build(
            inputs: [.init(provider: .antigravity, displayName: "Antigravity", snapshot: snapshot)],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)
    }

    /// 2026-07-16, one day after the fixture row, so the recorded usage falls inside the window.
    private static let now = Date(timeIntervalSince1970: 1_784_179_200)
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
