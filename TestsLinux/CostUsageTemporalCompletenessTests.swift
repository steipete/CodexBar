import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageTemporalCompletenessTests {
    @Test(arguments: [0.0, 4.0])
    func `same timestamp retains a known subtotal without pricing its unknown sibling`(cost: Double) throws {
        let timestamp = Self.date("2026-07-17T10:15:00Z")
        let reports = [
            CostUsageDailyReport(data: [], summary: nil, quotaSlices: [
                .init(timestamp: timestamp, totalTokens: 100, costUSD: cost),
            ]),
            CostUsageDailyReport(data: [], summary: nil, quotaSlices: [
                .init(timestamp: timestamp, totalTokens: 200, costUSD: nil),
            ]),
        ]
        let merged = CostUsageDailyReport.merged(reports, calendar: Self.calendar)
        let slice = try #require(merged.quotaSlices.first)
        #expect(slice.totalTokens == 300)
        #expect(slice.tokensAreComplete)
        #expect(slice.costUSD == cost)
        #expect(!slice.costIsComplete)
        #expect(merged.hourly.first?.costUSD == cost)
        #expect(merged.hourly.first?.costIsComplete == false)
        let window = try Self.window(report: merged)
        #expect(window.totalTokens == 300)
        #expect(window.tokensAreComplete)
        #expect(window.totalCostUSD == cost)
        #expect(!window.costIsComplete)
    }

    @Test
    func `invalid arithmetic affects only its own metric and never revives`() {
        var tokens = CostUsageTemporalTotals()
        tokens.add(totalTokens: Int.max, costUSD: 2)
        tokens.add(totalTokens: 1, costUSD: 3)
        tokens.add(totalTokens: 0, costUSD: 0)
        #expect(tokens.totalTokens == nil)
        #expect(!tokens.tokensAreComplete)
        #expect(tokens.costUSD == 5)
        #expect(tokens.costIsComplete)
        var dollars = CostUsageTemporalTotals()
        dollars.add(totalTokens: 100, costUSD: Double.greatestFiniteMagnitude)
        dollars.add(totalTokens: 200, costUSD: Double.greatestFiniteMagnitude)
        dollars.add(totalTokens: 0, costUSD: 0)
        #expect(dollars.totalTokens == 300)
        #expect(dollars.tokensAreComplete)
        #expect(dollars.costUSD == nil)
        #expect(!dollars.costIsComplete)
        var missing = CostUsageTemporalTotals()
        missing.add(totalTokens: 10, costUSD: nil)
        #expect(missing.costUSD == nil)
        #expect(!missing.costIsComplete)
        missing.add(totalTokens: -1, costUSD: 0)
        #expect(missing.totalTokens == nil)
        #expect(missing.costUSD == 0)
        #expect(!missing.costIsComplete)
    }

    @Test(arguments: [false, true])
    func `partial exact values survive nil daily cost and an hourly reset split`(split: Bool) throws {
        let timestamp = Self.date("2026-07-17T10:45:00Z")
        let report = CostUsageDailyReport(
            data: [Self.day(
                tokens: 300,
                cost: nil)],
            summary: nil,
            hourly: [.init(
                hour: Self.date("2026-07-17T10:00:00Z"),
                totalTokens: 300,
                costUSD: 4,
                costIsComplete: false)],
            quotaSlices: [.init(timestamp: timestamp, totalTokens: 300, costUSD: 4, costIsComplete: false)])
        let reset = split ? "2026-07-24T10:30:00Z" : "2026-07-23T18:00:00Z"
        let window = try Self.window(report: report, reset: reset)
        #expect(window.totalTokens == 300)
        #expect(window.tokensAreComplete)
        #expect(window.totalCostUSD == 4)
        #expect(!window.costIsComplete)
    }

    @Test
    func `contained daily fallback cannot turn explicitly partial temporal cost complete`() throws {
        let report = CostUsageDailyReport(
            data: [Self.day(
                tokens: 300,
                cost: 4)],
            summary: nil,
            quotaSlices: [.init(
                timestamp: Self.date("2026-07-17T10:15:00Z"),
                totalTokens: 300,
                costUSD: 4,
                costIsComplete: false)])
        let window = try Self.window(report: report)
        #expect(window.totalTokens == 300)
        #expect(window.tokensAreComplete)
        #expect(window.totalCostUSD == 4)
        #expect(!window.costIsComplete)
    }

    @Test
    func `coarse unknown cost retains other known contributions as partial`() throws {
        let report = CostUsageDailyReport(
            data: [Self.day(
                tokens: 300,
                cost: nil)],
            summary: nil,
            hourly: [
                .init(hour: Self.date("2026-07-17T10:00:00Z"), totalTokens: 100, costUSD: 4),
                .init(hour: Self.date("2026-07-17T11:00:00Z"), totalTokens: 200, costUSD: nil),
            ])
        let window = try Self.window(report: report)
        #expect(window.totalTokens == 300)
        #expect(window.totalCostUSD == 4)
        #expect(!window.costIsComplete)
    }

    @Test
    func `unmetered daily evidence qualifies otherwise known costs`() throws {
        let report = CostUsageDailyReport(
            data: [.init(
                date: "2026-07-17",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 300,
                costUSD: 4,
                modelsUsed: nil,
                modelBreakdowns: nil,
                unmeteredRequestCount: 1)],
            summary: nil)
        let window = try Self.window(report: report)
        #expect(window.totalTokens == 300)
        #expect(window.totalCostUSD == 4)
        #expect(!window.tokensAreComplete)
        #expect(!window.costIsComplete)
    }

    @Test
    func `contradictory hourly totals cannot certify exact evidence as complete`() throws {
        let report = CostUsageDailyReport(
            data: [],
            summary: nil,
            hourly: [.init(
                hour: Self.date("2026-07-17T10:00:00Z"),
                totalTokens: 100,
                costUSD: 1)],
            quotaSlices: [.init(
                timestamp: Self.date("2026-07-17T10:15:00Z"),
                totalTokens: 200,
                costUSD: 2)])
        let window = try Self.window(report: report)
        #expect(!window.tokensAreComplete)
        #expect(!window.costIsComplete)
    }

    @Test
    func `retained Codex report preserves independent temporal completeness flags`() throws {
        let timestamp = Self.date("2026-07-17T10:15:00Z")
        let report = CostUsageDailyReport(
            data: [Self.day(
                tokens: 300,
                cost: 0)],
            summary: nil,
            hourly: [.init(hour: timestamp, totalTokens: 300, costUSD: 0, costIsComplete: false)],
            quotaSlices: [.init(timestamp: timestamp, totalTokens: 300, costUSD: 0, costIsComplete: false)])
        let retained = try #require(CostUsageCodexPreviousReport(
            report: report, cache: CostUsageCache(), reportSinceKey: "2026-07-01", reportUntilKey: "2026-07-19"))
        let decoded = try JSONDecoder().decode(
            CostUsageCodexPreviousReport.self, from: JSONEncoder().encode(retained))
        #expect(decoded.report.hourly == report.hourly)
        #expect(decoded.report.quotaSlices == report.quotaSlices)
    }

    @Test(arguments: [Int64(0), Int64(4_000_000_000)])
    func `Codex scanner preserves authoritative partial costs at a shared timestamp`(nanos: Int64) throws {
        let timestamp = Self.date("2026-07-17T10:15:00Z")
        let model = "gpt-5.4"
        let row = CostUsageScanner.CodexUsageRow(
            day: "2026-07-17",
            model: model,
            turnID: "a",
            eventIndex: 0,
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            input: 100,
            cached: 0,
            output: 0,
            knownCostNanos: nanos)
        let unknown = CostUsageScanner.CodexUsageRow(
            day: row.day,
            model: model,
            turnID: "b",
            eventIndex: 1,
            timestampUnixMs: row.timestampUnixMs,
            input: 200,
            cached: 0,
            output: 0,
            unpricedTokens: 200)
        var cache = CostUsageCache()
        cache.files = ["/synthetic/session.jsonl": CostUsageScanner.makeFileUsage(
            mtimeUnixMs: row.timestampUnixMs ?? 0,
            size: 1,
            days: [row.day: [model: [300, 0, 0]]],
            parsedBytes: 1,
            sessionId: "s",
            codexRows: [row, unknown],
            codexScanComplete: true)]
        cache.days = [row.day: [model: [300, 0, 0]]]
        let range = CostUsageScanner.CostUsageDayRange(since: timestamp, until: timestamp, calendar: Self.calendar)
        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        let slice = try #require(report.quotaSlices.first)
        #expect(slice.totalTokens == 300)
        #expect(slice.tokensAreComplete)
        #expect(slice.costUSD == Double(nanos) / 1_000_000_000)
        #expect(!slice.costIsComplete)
    }

    @Test(arguments: [false, true])
    func `partial daily amount cannot cap independently priced exact requests`(split: Bool) throws {
        let timestamp = Self.date("2026-07-17T10:45:00Z")
        let report = CostUsageDailyReport(
            data: [.init(
                date: "2026-07-17",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 300,
                costUSD: 1,
                modelsUsed: nil,
                modelBreakdowns: [
                    .init(modelName: "fixture-partial", costUSD: nil, totalTokens: 200),
                    .init(modelName: "fixture-priced", costUSD: 1, totalTokens: 100),
                ])],
            summary: nil,
            quotaSlices: [.init(timestamp: timestamp, totalTokens: 300, costUSD: 1.5, costIsComplete: false)])
        let window = try Self.window(
            report: report, reset: split ? "2026-07-24T10:30:00Z" : "2026-07-23T18:00:00Z")
        #expect(window.totalTokens == 300)
        #expect(window.totalCostUSD == 1.5)
        #expect(!window.costIsComplete)
    }

    @Test(arguments: [UsageProvider.codex, .claude])
    func `native report builders do not overflow before temporal aggregation`(provider: UsageProvider) throws {
        let timestamp = Self.date("2026-07-17T10:45:00Z")
        let millis = Int64(timestamp.timeIntervalSince1970 * 1000)
        let range = CostUsageScanner.CostUsageDayRange(since: timestamp, until: timestamp, calendar: Self.calendar)
        var cache = CostUsageCache()
        let report: CostUsageDailyReport
        if provider == .codex {
            let model = "gpt-5.4"
            let row = CostUsageScanner.CodexUsageRow(
                day: range.sinceKey,
                model: model,
                turnID: "overflow",
                eventIndex: 0,
                timestampUnixMs: millis,
                input: Int.max,
                cached: 0,
                output: 1,
                knownCostNanos: 0)
            cache.days = [range.sinceKey: [model: [Int.max, 0, 1]]]
            cache.files = ["/synthetic/codex.jsonl": CostUsageScanner.makeFileUsage(
                mtimeUnixMs: millis,
                size: 1,
                days: cache.days,
                parsedBytes: 1,
                sessionId: "overflow",
                codexRows: [row],
                codexScanComplete: true)]
            // A later valid zero day must not revive an overflowed summary counter.
            let nextDay = "2026-07-18"
            cache.days[nextDay] = [model: [0, 0, 0]]
            let extended = CostUsageScanner.CostUsageDayRange(
                since: timestamp, until: Self.date("2026-07-18T12:00:00Z"), calendar: Self.calendar)
            report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: extended)
        } else {
            let model = "claude-opus-4"
            let row = CostUsageScanner.ClaudeUsageRow(
                dayKey: range.sinceKey,
                model: model,
                sessionId: "overflow",
                messageId: "m",
                requestId: "r",
                timestampUnixMs: millis,
                isSidechain: false,
                pathRole: .parent,
                input: Int.max,
                cacheRead: 0,
                cacheCreate: 0,
                cacheCreate1h: nil,
                output: 1,
                costNanos: 0,
                costPriced: true)
            cache.days = [range.sinceKey: [model: [Int.max, 0, 0, 1, 0, 1, 1, 0]]]
            cache.files = ["/synthetic/claude.jsonl": CostUsageScanner.makeFileUsage(
                mtimeUnixMs: millis, size: 1, days: cache.days, parsedBytes: 1, claudeRows: [row])]
            report = CostUsageScanner.buildClaudeReportFromCache(cache: cache, range: range)
            #expect(report.summary?.totalInputTokens == Int.max)
            #expect(report.summary?.totalOutputTokens == 1)
        }
        #expect(report.data.first?.totalTokens == nil)
        #expect(report.summary?.totalTokens == nil)
        #expect(report.data.first?.costUSD == 0)
        #expect(try Self.window(report: report).totalCostUSD == 0)
        let slice = try #require(report.quotaSlices.first)
        #expect(slice.totalTokens == nil)
        #expect(!slice.tokensAreComplete)
        #expect(slice.costUSD == 0)
        #expect(slice.costIsComplete)
    }

    @Test(arguments: [false, true])
    func `entirely unknown exact metrics do not erase a known hourly residual`(unknownTokens: Bool) throws {
        let exact = CostUsageDailyReport(data: [], summary: nil, quotaSlices: [.init(
            timestamp: Self.date("2026-07-17T10:15:00Z"),
            totalTokens: unknownTokens ? nil : 100,
            costUSD: unknownTokens ? 2 : nil)])
        let legacy = CostUsageDailyReport(data: [], summary: nil, hourly: [.init(
            hour: Self.date("2026-07-17T10:00:00Z"), totalTokens: 200, costUSD: 4)])
        let window = try Self.window(report: .merged([exact, legacy], calendar: Self.calendar))
        #expect(window.totalTokens == (unknownTokens ? 200 : 300))
        #expect(window.totalCostUSD == (unknownTokens ? 6 : 4))
        #expect(window.tokensAreComplete == !unknownTokens)
        #expect(window.costIsComplete == unknownTokens)
    }

    private static func window(
        report: CostUsageDailyReport,
        reset: String = "2026-07-23T18:00:00Z") throws -> CostUsageQuotaWeek
    {
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: report, now: self.date("2026-07-19T12:00:00Z"), historyDays: 30, calendar: self.calendar)
        return try #require(snapshot.quotaWeekSummaries(resetAt: self.date(reset), calendar: self.calendar).first)
    }

    private static func day(tokens: Int?, cost: Double?) -> CostUsageDailyReport.Entry {
        .init(
            date: "2026-07-17",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    private static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
}
