import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct NativeResetDSTTests {
    @Test
    func `MiniMax next day reset retains its clock time after a spring gap`() throws {
        let now = try Self.date("2026-03-09T03:00:00Z") // March 8 at 23:00 in New York.
        let html = """
        <div>Coding Plan Pro</div>
        <div>Available usage: 1,500 prompts / 1.5 hours</div>
        <div>Used 75%</div>
        <div>Resets at 02:30 (America/New_York)</div>
        """
        let snapshot = try MiniMaxUsageParser.parse(html: html, now: now)
        let expected = try Self.date("2026-03-09T06:30:00Z")

        #expect(snapshot.resetsAt == expected)

        let monthEnd = try Self.date("2026-04-01T03:00:00Z")
        let nextMonth = try Self.date("2026-04-01T06:30:00Z")
        #expect(try MiniMaxUsageParser.parse(html: html, now: monthEnd).resetsAt == nextMonth)

        let repeatedTimeHTML = html.replacingOccurrences(of: "02:30", with: "01:30")
        let firstReset = try Self.date("2026-11-01T05:30:00Z")
        #expect(try MiniMaxUsageParser.parse(html: repeatedTimeHTML, now: firstReset).resetsAt == firstReset)
        let betweenRepeats = try Self.date("2026-11-01T06:15:00Z")
        let nextDay = try Self.date("2026-11-02T06:30:00Z")
        #expect(try MiniMaxUsageParser.parse(html: repeatedTimeHTML, now: betweenRepeats).resetsAt == nextDay)
    }

    @Test
    func `Codex next day reset parses a clock time missing from today`() throws {
        let calendar = try Self.calendar("America/New_York")
        let now = try Self.date("2026-03-09T03:00:00Z") // March 8 at 23:00 in New York.
        let expected = try Self.date("2026-03-09T06:30:00Z")

        #expect(CodexStatusProbe.parseResetDate(from: "02:30", now: now, calendar: calendar) == expected)

        let beforeGap = try Self.date("2026-03-08T04:00:00Z")
        let normalizedGap = try Self.date("2026-03-08T07:30:00Z")
        #expect(CodexStatusProbe.parseResetDate(from: "02:30", now: beforeGap, calendar: calendar) == normalizedGap)

        let firstReset = try Self.date("2026-11-01T05:30:00Z")
        #expect(CodexStatusProbe.parseResetDate(from: "01:30", now: firstReset, calendar: calendar) == firstReset)
        let betweenRepeats = try Self.date("2026-11-01T06:15:00Z")
        let nextDay = try Self.date("2026-11-02T06:30:00Z")
        #expect(CodexStatusProbe.parseResetDate(from: "01:30", now: betweenRepeats, calendar: calendar) == nextDay)
    }

    @Test
    func `workday pace includes Monday midnight after a skipped Sunday midnight`() throws {
        let calendar = try Self.calendar("America/Santiago")
        let now = try Self.date("2026-09-07T03:30:00Z")
        let reset = try Self.date("2026-09-07T15:00:00Z")
        let window = RateWindow(usedPercent: 50, windowMinutes: 10080, resetsAt: reset, resetDescription: nil)
        let pace = try #require(UsagePace.weekly(window: window, now: now, workDays: 5, calendar: calendar))

        // The window contains 13 hours on the first Monday, 96 Tuesday-Friday, and 12 on the last Monday.
        #expect(abs(pace.expectedUsedPercent - 109.5 / 121 * 100) < 1e-9)
    }

    @Test
    func `quota projection retains a short civil day ending exactly at reset`() throws {
        let calendar = try Self.calendar("America/Santiago")
        let now = try Self.date("2026-09-06T15:00:00Z")
        let reset = try Self.date("2026-09-07T03:00:00Z")
        let snapshot = Self.snapshot(now: now)
        let week = try #require(snapshot.quotaWeekSummaries(
            resetAt: reset,
            weekCount: 1,
            now: now,
            calendar: calendar).first)

        #expect(week.totalTokens == 100)
        #expect(week.totalCostUSD == 1)
    }

    @Test @MainActor
    func `selected spend day excludes the following midnight hour after a DST gap`() throws {
        let calendar = try Self.calendar("America/Santiago")
        let now = try Self.date("2026-09-06T15:00:00Z")
        let model = SpendDashboardModel.build(
            inputs: [.init(provider: .codex, displayName: "Codex", snapshot: Self.snapshot(now: now))],
            requestedDays: 7,
            now: now,
            calendar: calendar,
            selectedDay: now)
        let group = try #require(model.groups.first)
        let start = try Self.date("2026-09-06T04:00:00Z")
        let end = try Self.date("2026-09-07T03:00:00Z")

        #expect(spendToolActivityRange(group: group) == start..<end)
    }

    private static func calendar(_ identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: identifier))
        return calendar
    }

    private static func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    private static func snapshot(now: Date) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 100,
            sessionCostUSD: 1,
            last30DaysTokens: 100,
            last30DaysCostUSD: 1,
            historyCoverageIsEstablished: true,
            daily: [.init(
                date: "2026-09-06",
                inputTokens: 100,
                outputTokens: 0,
                totalTokens: 100,
                costUSD: 1,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: now)
    }
}
