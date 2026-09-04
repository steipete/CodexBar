import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLICostClaudeDetailTests {
    @Test
    func `Claude detail leaves default text output unchanged`() {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 0.1,
            last30DaysTokens: 10,
            last30DaysCostUSD: 0.1,
            daily: [Self.entry(date: "2026-08-27", tokens: 10, cost: 0.1, model: "claude-sonnet-4")],
            updatedAt: Date(timeIntervalSince1970: 1_777_000_000))

        let output = CodexBarCLI.renderCostText(provider: .claude, snapshot: snapshot, useColor: false)

        #expect(!output.contains("Daily breakdown"))
        #expect(!output.contains("Top models"))
    }

    @Test
    func `daily detail uses the configured bucket calendar and labels the interval`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 14 * 60 * 60))
        let updatedAt = try #require(ISO8601DateFormatter().date(from: "2026-08-26T12:30:00Z"))
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 20,
            sessionCostUSD: 0.2,
            last30DaysTokens: 20,
            last30DaysCostUSD: 0.2,
            historyDays: 30,
            daily: [
                Self.entry(date: "2026-08-21", tokens: 10, cost: 0.1, model: "claude-sonnet-4-20250514"),
                Self.entry(date: "2026-08-27", tokens: 10, cost: 0.1, model: "claude-sonnet-4-20250514"),
            ],
            updatedAt: updatedAt)

        let output = CodexBarCLI.renderCostText(
            provider: .claude,
            snapshot: snapshot,
            useColor: false,
            calendar: calendar,
            includeBreakdown: true)

        #expect(output.contains("Daily breakdown (last 7 calendar days):"))
        #expect(output.contains("2026-08-21:"))
        #expect(output.contains("2026-08-27:"))
        #expect(!output.contains("last 2 days"))
    }

    @Test
    func `detail does not change other provider text output`() {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 0.1,
            last30DaysTokens: 10,
            last30DaysCostUSD: 0.1,
            daily: [Self.entry(date: "2026-08-27", tokens: 10, cost: 0.1, model: "gpt-5.4")],
            updatedAt: Date(timeIntervalSince1970: 1_777_000_000))

        let output = CodexBarCLI.renderCostText(provider: .codex, snapshot: snapshot, useColor: false)

        #expect(!output.contains("Daily breakdown"))
        #expect(!output.contains("Top models"))
    }

    @Test
    func `model aggregation stays unknown on integer overflow`() throws {
        let updatedAt = try #require(ISO8601DateFormatter().date(from: "2026-08-27T12:00:00Z"))
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyCoverageIsEstablished: true,
            daily: [
                Self.entry(
                    date: "2026-08-26",
                    tokens: Int.max - 1,
                    cost: 1.0,
                    model: "claude-sonnet-4-20250514"),
                Self.entry(
                    date: "2026-08-27",
                    tokens: 2,
                    cost: 1.0,
                    model: "claude-sonnet-4-20250514"),
            ],
            updatedAt: updatedAt)

        let output = CodexBarCLI.renderCostText(
            provider: .claude,
            snapshot: snapshot,
            useColor: false,
            calendar: Self.utcCalendar,
            includeBreakdown: true)

        #expect(output.contains("Top models (Last 30 days — partial):"))
        #expect(output.contains("Ranking is partial"))
    }

    @Test
    func `model ranking distinguishes unattributed usage from explicit zero`() throws {
        let updatedAt = try #require(ISO8601DateFormatter().date(from: "2026-08-27T12:00:00Z"))
        let attributed = Self.entry(
            date: "2026-08-27",
            tokens: 10,
            cost: 0.1,
            model: "claude-sonnet-4-20250514")
        let positiveUnattributed = Self.entry(date: "2026-08-26", tokens: 5, cost: 0.05)
        let explicitZero = Self.entry(date: "2026-08-26", tokens: 0, cost: 0)

        let partialSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 15,
            sessionCostUSD: 0.15,
            last30DaysTokens: 15,
            last30DaysCostUSD: 0.15,
            historyCoverageIsEstablished: true,
            daily: [positiveUnattributed, attributed],
            updatedAt: updatedAt)
        let completeSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 0.1,
            last30DaysTokens: 10,
            last30DaysCostUSD: 0.1,
            historyCoverageIsEstablished: true,
            daily: [explicitZero, attributed],
            updatedAt: updatedAt)

        let partial = CodexBarCLI.renderCostText(
            provider: .claude,
            snapshot: partialSnapshot,
            useColor: false,
            calendar: Self.utcCalendar,
            includeBreakdown: true)
        let complete = CodexBarCLI.renderCostText(
            provider: .claude,
            snapshot: completeSnapshot,
            useColor: false,
            calendar: Self.utcCalendar,
            includeBreakdown: true)

        #expect(partial.contains("Top models (Last 30 days — partial):"))
        #expect(partial.contains("Ranking is partial"))
        #expect(complete.contains("Top models (Last 30 days):"))
        #expect(!complete.contains("Ranking is partial"))
    }

    @Test
    func `stale history falls back to recorded days capped at the requested interval`() {
        let old = [
            Self.entry(date: "2020-01-01", tokens: 10, cost: 0.1, model: "claude-sonnet-4-20250514"),
            Self.entry(date: "2020-01-02", tokens: 20, cost: 0.2, model: "claude-sonnet-4-20250514"),
            Self.entry(date: "2020-01-03", tokens: 30, cost: 0.3, model: "claude-sonnet-4-20250514"),
        ]
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 60,
            last30DaysCostUSD: 0.6,
            historyDays: 1,
            daily: old,
            updatedAt: Date(timeIntervalSince1970: 1_777_000_000))

        let output = CodexBarCLI.renderCostText(
            provider: .claude,
            snapshot: snapshot,
            useColor: false,
            includeBreakdown: true)

        // One recorded day (not three): the fallback honors the requested interval
        // and never labels stale rows as calendar days.
        #expect(output.contains("Daily breakdown (last 1 recorded day):"))
        #expect(output.contains("2020-01-03:"))
        #expect(!output.contains("2020-01-02:"))
        #expect(!output.contains("calendar day"))
        #expect(output.contains("Top models ("))
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func entry(
        date: String,
        tokens: Int,
        cost: Double,
        model: String? = nil) -> CostUsageDailyReport.Entry
    {
        let breakdowns = model.map {
            [CostUsageDailyReport.ModelBreakdown(modelName: $0, costUSD: cost, totalTokens: tokens)]
        } ?? []
        return CostUsageDailyReport.Entry(
            date: date,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: breakdowns)
    }
}
