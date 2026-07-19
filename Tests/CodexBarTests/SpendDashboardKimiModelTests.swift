import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendDashboardKimiModelTests {
    @Test
    func `token-only Kimi history joins global models without creating a currency group`() {
        let priced = SpendDashboardModel.ProviderInput(
            provider: .codex,
            displayName: "Codex",
            snapshot: Self.snapshot(currency: "USD", cost: 2, tokens: 10, model: "gpt-test"))
        let kimi = SpendDashboardModel.ProviderInput(
            id: "kimi:local",
            provider: .kimi,
            displayName: "Kimi Code CLI",
            modelProviderName: "Kimi",
            snapshot: Self.snapshot(currency: "XXX", cost: nil, tokens: 90, model: "kimi-code/k3"))
        let model = SpendDashboardModel.build(
            inputs: [priced, kimi],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)

        #expect(model.groups.map(\.currencyCode) == ["USD"])
        #expect(model.modelAnalysis.rows.map(\.displayName) == ["Kimi K3", "gpt-test"])
        #expect(model.modelAnalysis.rows.map(\.totalTokens) == [90, 10])
        #expect(model.modelAnalysis.rows.first?.rawModelNames == ["kimi-code/k3"])
        #expect(model.modelAnalysis.rows.first?.providerNames == ["Kimi"])
        #expect(model.modelAnalysis.trackedTokenTotal == 100)
        #expect(model.modelAnalysis.tokenCoverage == .complete)
    }

    @Test
    func `Kimi aliases use product names while preserving raw identifiers`() {
        let kimi = SpendDashboardModel.ProviderInput(
            id: "kimi:local",
            provider: .kimi,
            displayName: "Kimi Code CLI",
            modelProviderName: "Kimi",
            snapshot: Self.multiModelSnapshot(models: [
                ("kimi-code/k3", 50),
                ("kimi-k2.5", 40),
                ("kimi-code/kimi-for-coding", 30),
                ("kimi-code/kimi-for-coding-highspeed", 20),
            ]))
        let model = SpendDashboardModel.build(
            inputs: [kimi],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)

        #expect(model.modelAnalysis.rows.map(\.displayName) == [
            "Kimi K3",
            "Kimi K2.5",
            "Kimi for Coding",
            "Kimi for Coding High-Speed",
        ])
        #expect(model.modelAnalysis.rows.map(\.rawModelNames) == [
            ["kimi-code/k3"],
            ["kimi-k2.5"],
            ["kimi-code/kimi-for-coding"],
            ["kimi-code/kimi-for-coding-highspeed"],
        ])
    }

    private static func snapshot(
        currency: String,
        cost: Double?,
        tokens: Int,
        model: String) -> CostUsageTokenSnapshot
    {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: [.init(modelName: model, costUSD: cost, totalTokens: tokens)])
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            currencyCode: currency,
            historyDays: 30,
            daily: [entry],
            updatedAt: self.now)
    }

    private static func multiModelSnapshot(models: [(name: String, tokens: Int)]) -> CostUsageTokenSnapshot {
        let totalTokens = models.map(\.tokens).reduce(0, +)
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: totalTokens,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: models.map {
                .init(modelName: $0.name, costUSD: nil, totalTokens: $0.tokens)
            })
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            currencyCode: "XXX",
            historyDays: 30,
            daily: [entry],
            updatedAt: self.now)
    }

    private static let now = Date(timeIntervalSince1970: 1_784_179_200)
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
