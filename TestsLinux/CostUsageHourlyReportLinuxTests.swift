import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageHourlyReportLinuxTests {
    @Test
    func `codex report splits billed cost across hours on the reset day`() {
        let calendar = Self.utcCalendar
        let day = Self.utcDate(year: 2026, month: 7, day: 11, hour: 12)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day, calendar: calendar)
        let dayKey = range.sinceKey
        let model = "gpt-5.4"
        let before = Self.utcDate(year: 2026, month: 7, day: 11, hour: 14)
        let after = Self.utcDate(year: 2026, month: 7, day: 11, hour: 15)
        let beforeRow = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "before",
            eventIndex: 0,
            timestampUnixMs: Int64(before.timeIntervalSince1970 * 1000),
            input: 100,
            cached: 0,
            output: 0,
            knownCostNanos: 2_000_000_000,
            pricingMode: "standard")
        let afterRow = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "after",
            eventIndex: 1,
            timestampUnixMs: Int64(after.timeIntervalSince1970 * 1000),
            input: 200,
            cached: 0,
            output: 0,
            knownCostNanos: 4_000_000_000,
            pricingMode: "standard")
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: afterRow.timestampUnixMs ?? 0,
            size: 1,
            days: [dayKey: [model: [300, 0, 0]]],
            parsedBytes: 1,
            sessionId: "session",
            codexRows: [beforeRow, afterRow],
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files = ["/session.jsonl": usage]
        cache.days = [dayKey: [model: [300, 0, 0]]]
        cache.scanSinceKey = dayKey
        cache.scanUntilKey = dayKey
        cache.timeZoneIdentifier = calendar.timeZone.identifier

        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        #expect(report.data.first?.costUSD == 6)
        #expect(report.hourly.count == 2)
        let beforeHour = report.hourly.first { $0.hour == calendar.dateInterval(of: .hour, for: before)?.start }
        let afterHour = report.hourly.first { $0.hour == calendar.dateInterval(of: .hour, for: after)?.start }
        #expect(beforeHour?.costUSD == 2)
        #expect(beforeHour?.totalTokens == 100)
        #expect(afterHour?.costUSD == 4)
        #expect(afterHour?.totalTokens == 200)

        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: report,
            now: after,
            historyDays: 30,
            calendar: calendar)
        #expect(snapshot.hourly == report.hourly)
        let weeks = snapshot.quotaWeekSummaries(
            resetAt: after,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            calendar: calendar)
        #expect(weeks.first { $0.isCurrent }?.totalCostUSD == 4)
        #expect(weeks.first { $0.offset == 1 }?.totalCostUSD == 2)
    }

    @Test
    func `claude report assigns request cost to the hour it happened`() {
        let calendar = Self.utcCalendar
        let day = Self.utcDate(year: 2026, month: 7, day: 11, hour: 12)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day, calendar: calendar)
        let dayKey = range.sinceKey
        let model = "claude-opus-4"
        let before = Self.utcDate(year: 2026, month: 7, day: 11, hour: 14)
        let after = Self.utcDate(year: 2026, month: 7, day: 11, hour: 15)
        let beforeRow = CostUsageScanner.ClaudeUsageRow(
            dayKey: dayKey,
            model: model,
            sessionId: "s",
            messageId: "m1",
            requestId: "r1",
            timestampUnixMs: Int64(before.timeIntervalSince1970 * 1000),
            isSidechain: false,
            pathRole: .parent,
            input: 50,
            cacheRead: 0,
            cacheCreate: 0,
            cacheCreate1h: nil,
            output: 10,
            costNanos: 1_500_000_000,
            costPriced: true)
        let afterRow = CostUsageScanner.ClaudeUsageRow(
            dayKey: dayKey,
            model: model,
            sessionId: "s",
            messageId: "m2",
            requestId: "r2",
            timestampUnixMs: Int64(after.timeIntervalSince1970 * 1000),
            isSidechain: false,
            pathRole: .parent,
            input: 80,
            cacheRead: 0,
            cacheCreate: 0,
            cacheCreate1h: nil,
            output: 20,
            costNanos: 3_500_000_000,
            costPriced: true)
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: afterRow.timestampUnixMs ?? 0,
            size: 1,
            days: [:],
            parsedBytes: 1,
            claudeRows: [beforeRow, afterRow])
        var cache = CostUsageCache()
        cache.files = ["/claude.jsonl": usage]
        cache.days = [dayKey: [model: [130, 0, 0, 30, 5_000_000_000, 2, 2, 0]]]
        cache.scanSinceKey = dayKey
        cache.scanUntilKey = dayKey
        cache.timeZoneIdentifier = calendar.timeZone.identifier

        let report = CostUsageScanner.buildClaudeReportFromCache(cache: cache, range: range)
        let beforeHour = report.hourly.first { $0.hour == calendar.dateInterval(of: .hour, for: before)?.start }
        let afterHour = report.hourly.first { $0.hour == calendar.dateInterval(of: .hour, for: after)?.start }
        #expect(beforeHour?.totalTokens == 60)
        #expect(afterHour?.totalTokens == 100)
        let hourlyCost = (beforeHour?.costUSD ?? 0) + (afterHour?.costUSD ?? 0)
        #expect(abs((report.data.first?.costUSD ?? 0) - hourlyCost) < 1e-9)
        #expect((beforeHour?.costUSD ?? 0) > 0)
        #expect((afterHour?.costUSD ?? 0) > 0)

        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: report,
            now: after,
            historyDays: 30,
            calendar: calendar)
        let weeks = snapshot.quotaWeekSummaries(
            resetAt: after,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            calendar: calendar)
        #expect(weeks.first { $0.isCurrent }?.totalCostUSD == afterHour?.costUSD)
        #expect(weeks.first { $0.offset == 1 }?.totalCostUSD == beforeHour?.costUSD)
    }

    private static func utcDate(year: Int, month: Int, day: Int, hour: Int) -> Date {
        var components = DateComponents()
        components.calendar = self.utcCalendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return components.date!
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
