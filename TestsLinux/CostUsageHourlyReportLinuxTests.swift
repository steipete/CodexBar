import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageHourlyReportLinuxTests {
    @Test
    func `codex report preserves authoritative row costs across hours`() {
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
            knownCostNanos: 1_000_000_000,
            pricingMode: "standard")
        let afterRow = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "after",
            eventIndex: 1,
            timestampUnixMs: Int64(after.timeIntervalSince1970 * 1000),
            input: 100,
            cached: 0,
            output: 0,
            knownCostNanos: 9_000_000_000,
            pricingMode: "standard")
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: afterRow.timestampUnixMs ?? 0,
            size: 1,
            days: [dayKey: [model: [200, 0, 0]]],
            parsedBytes: 1,
            sessionId: "session",
            codexRows: [beforeRow, afterRow],
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files = ["/session.jsonl": usage]
        cache.days = [dayKey: [model: [200, 0, 0]]]
        cache.scanSinceKey = dayKey
        cache.scanUntilKey = dayKey
        cache.timeZoneIdentifier = calendar.timeZone.identifier

        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        #expect(report.data.first?.costUSD == 10)
        #expect(report.hourly.count == 2)
        let beforeHour = report.hourly.first { $0.hour == calendar.dateInterval(of: .hour, for: before)?.start }
        let afterHour = report.hourly.first { $0.hour == calendar.dateInterval(of: .hour, for: after)?.start }
        #expect(beforeHour?.costUSD == 1)
        #expect(beforeHour?.totalTokens == 100)
        #expect(afterHour?.costUSD == 9)
        #expect(afterHour?.totalTokens == 100)
        #expect(report.quotaSlices.count == 2)
        let beforeSlice = report.quotaSlices.first { $0.timestamp == before }
        let afterSlice = report.quotaSlices.first { $0.timestamp == after }
        #expect(beforeSlice?.costUSD == 1)
        #expect(beforeSlice?.totalTokens == 100)
        #expect(afterSlice?.costUSD == 9)
        #expect(afterSlice?.totalTokens == 100)

        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: report,
            now: after,
            historyDays: 30,
            calendar: calendar)
        #expect(snapshot.hourly == report.hourly)
        #expect(snapshot.quotaSlices == report.quotaSlices)
        let weeks = snapshot.quotaWeekSummaries(
            resetAt: after,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            calendar: calendar)
        #expect(weeks.first { $0.isCurrent }?.totalCostUSD == 9)
        #expect(weeks.first { $0.offset == 1 }?.totalCostUSD == 1)
    }

    @Test
    func `codex requests on either side of a half hour reset enter adjacent windows`() {
        let calendar = Self.utcCalendar
        let day = Self.utcDate(year: 2026, month: 7, day: 11, hour: 12)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day, calendar: calendar)
        let dayKey = range.sinceKey
        let model = "gpt-5.4"
        let resetAt = Self.utcDate(year: 2026, month: 7, day: 11, hour: 15, minute: 30)
        let before = Self.utcDate(year: 2026, month: 7, day: 11, hour: 15, minute: 15)
        let after = Self.utcDate(year: 2026, month: 7, day: 11, hour: 15, minute: 45)
        let beforeRow = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "before-half-hour-reset",
            eventIndex: 0,
            timestampUnixMs: Int64(before.timeIntervalSince1970 * 1000),
            input: 100,
            cached: 0,
            output: 0,
            knownCostNanos: 1_000_000_000,
            pricingMode: "standard")
        let afterRow = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "after-half-hour-reset",
            eventIndex: 1,
            timestampUnixMs: Int64(after.timeIntervalSince1970 * 1000),
            input: 900,
            cached: 0,
            output: 0,
            knownCostNanos: 9_000_000_000,
            pricingMode: "standard")
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: afterRow.timestampUnixMs ?? 0,
            size: 1,
            days: [dayKey: [model: [1_000, 0, 0]]],
            parsedBytes: 1,
            sessionId: "half-hour-session",
            codexRows: [beforeRow, afterRow],
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files = ["/half-hour-session.jsonl": usage]
        cache.days = [dayKey: [model: [1_000, 0, 0]]]
        cache.scanSinceKey = dayKey
        cache.scanUntilKey = dayKey
        cache.timeZoneIdentifier = calendar.timeZone.identifier

        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        #expect(report.data.first?.costUSD == 10)
        #expect(report.quotaSlices.map(\.timestamp) == [before, after])
        let beforeSlice = report.quotaSlices.first { $0.timestamp == before }
        let afterSlice = report.quotaSlices.first { $0.timestamp == after }
        #expect(beforeSlice?.costUSD == 1)
        #expect(beforeSlice?.totalTokens == 100)
        #expect(afterSlice?.costUSD == 9)
        #expect(afterSlice?.totalTokens == 900)
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: report,
            now: after,
            historyDays: 30,
            calendar: calendar)
        let weeks = snapshot.quotaWeekSummaries(
            resetAt: resetAt,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            now: after,
            calendar: calendar)

        #expect(weeks.first { $0.isCurrent }?.totalCostUSD == 9)
        #expect(weeks.first { $0.isCurrent }?.totalTokens == 900)
        #expect(weeks.first { $0.offset == 1 }?.totalCostUSD == 1)
        #expect(weeks.first { $0.offset == 1 }?.totalTokens == 100)
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

    @Test
    func `previous report payload without hourly data falls back to daily quota totals`() throws {
        let calendar = Self.utcCalendar
        let now = Self.utcDate(year: 2026, month: 7, day: 15, hour: 12)
        let resetAt = Self.utcDate(year: 2026, month: 7, day: 18, hour: 15)
        let updatedAtUnixMs = Int64(now.timeIntervalSince1970 * 1000)
        let payload = Data("""
        {
          "data": [{"date":"2026-07-13","totalTokens":700,"costUSD":7}],
          "updatedAtUnixMs": \(updatedAtUnixMs),
          "scanSinceKey": "2026-07-01",
          "scanUntilKey": "2026-07-15",
          "timeZoneIdentifier": "GMT",
          "roots": {"/synthetic/root": 1}
        }
        """.utf8)

        let retained = try JSONDecoder().decode(CostUsageCodexPreviousReport.self, from: payload)
        #expect(retained.report.hourly.isEmpty)
        #expect(retained.report.quotaSlices.isEmpty)
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: retained.report,
            now: now,
            historyDays: 30,
            calendar: calendar)
        let current = snapshot.quotaWeekSummaries(
            resetAt: resetAt,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            calendar: calendar).first { $0.isCurrent }

        #expect(current?.totalCostUSD == 7)
        #expect(current?.totalTokens == 700)
    }

    @Test
    func `previous report payload round trips exact quota slices`() throws {
        let first = Self.utcDate(year: 2026, month: 7, day: 11, hour: 15, minute: 15)
        let second = Self.utcDate(year: 2026, month: 7, day: 11, hour: 15, minute: 45)
        let report = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-11",
                    inputTokens: 1_000,
                    outputTokens: 0,
                    totalTokens: 1_000,
                    costUSD: 10,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: nil),
            ],
            summary: nil,
            quotaSlices: [
                CostUsageTimedEntry(timestamp: first, totalTokens: 100, costUSD: 1),
                CostUsageTimedEntry(timestamp: second, totalTokens: 900, costUSD: 9),
            ])
        var cache = CostUsageCache()
        cache.lastScanUnixMs = Int64(second.timeIntervalSince1970 * 1000)
        cache.timeZoneIdentifier = Self.utcCalendar.timeZone.identifier
        cache.roots = ["/synthetic/root": 1]
        let retained = try #require(CostUsageCodexPreviousReport(
            report: report,
            cache: cache,
            reportSinceKey: "2026-07-01",
            reportUntilKey: "2026-07-15"))

        let payload = try JSONEncoder().encode(retained)
        let decoded = try JSONDecoder().decode(CostUsageCodexPreviousReport.self, from: payload)

        #expect(decoded.report.hourly.isEmpty)
        #expect(decoded.report.quotaSlices == report.quotaSlices)
    }

    private static func utcDate(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.calendar = self.utcCalendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date!
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
