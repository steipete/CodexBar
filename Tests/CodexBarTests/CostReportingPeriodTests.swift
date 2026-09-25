import Commander
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

struct CostReportingPeriodTests {
    private let calendar = CostUsageBucketTimeZone.calendar(identifier: "America/Los_Angeles")

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    @Test(arguments: [
        ("2026-01-31T20:00:00Z", 31, "2026-01-01T08:00:00Z"),
        ("2026-02-01T08:00:00Z", 1, "2026-02-01T08:00:00Z"),
        ("2026-02-28T20:00:00Z", 28, "2026-02-01T08:00:00Z"),
        ("2024-02-29T20:00:00Z", 29, "2024-02-01T08:00:00Z"),
        ("2026-03-09T07:00:00Z", 9, "2026-03-01T08:00:00Z"),
        ("2026-11-02T08:00:00Z", 2, "2026-11-01T07:00:00Z"),
    ])
    func `month starts and day counts follow the bucket calendar`(value: (String, Int, String)) {
        let now = self.date(value.0)
        #expect(CostReportingPeriod.monthToDate.days(now: now, calendar: self.calendar) == value.1)
        #expect(CostReportingPeriod.monthToDate.bounds(now: now, calendar: self.calendar).lowerBound == self
            .date(value.2))
    }

    @Test
    func `cache identity distinguishes semantic periods rollover and pinned zones`() {
        let january = self.date("2026-02-01T07:59:59Z")
        let february = january.addingTimeInterval(1)
        let period = CostReportingPeriod.monthToDate
        #expect(period.identity(now: january, calendar: self.calendar) != period.identity(
            now: february,
            calendar: self.calendar))
        #expect(period.identity(now: february, calendar: self.calendar) != CostReportingPeriod.rolling(days: 1)
            .identity(
                now: february,
                calendar: self.calendar))
        #expect(period.days(now: january, calendar: self.calendar) == 31)
        #expect(period.days(now: january, calendar: CostUsageBucketTimeZone.calendar(identifier: "UTC")) == 1)
    }

    @Test
    func `legacy windows and explicit CLI days retain rolling semantics`() throws {
        #expect(CostReportingPeriod.migrated(rawValue: nil, legacyDays: 90) == .rolling(days: 90))
        #expect(CostReportingPeriod.migrated(rawValue: nil, legacyDays: nil) == .rolling(days: 30))
        #expect(CostReportingPeriod.migrated(rawValue: "invalid", legacyDays: 999) == .rolling(days: 365))
        let saved = CostReportingPeriod.migrated(rawValue: "month-to-date", legacyDays: 90)
        let parser = CommandParser(signature: CodexBarCLI._costSignatureForTesting())
        #expect(try CodexBarCLI.decodeCostReportingPeriod(from: parser.parse(arguments: []), saved: saved) == saved)
        #expect(try CodexBarCLI.decodeCostReportingPeriod(
            from: parser.parse(arguments: ["--days", "7", "--period", "month-to-date"]),
            saved: saved) == .rolling(days: 7))
        #expect(try CodexBarCLI.decodeCostReportingPeriod(
            from: parser.parse(arguments: ["--period", "all"]),
            saved: saved) == .allTime)
    }

    @Test @MainActor
    func `settings migration persists the semantic selection without changing legacy rolling windows`() {
        let defaults = InMemoryUserDefaults(values: [CostReportingPeriod.legacyDaysKey: 90])
        let settings = testSettingsStore(suiteName: "CostReportingPeriodTests", userDefaults: defaults)
        #expect(settings.costReportingPeriod == .rolling(days: 90))
        settings.costReportingPeriod = .monthToDate
        #expect(defaults.string(forKey: CostReportingPeriod.defaultsKey) == "month-to-date")
        let reloaded = testSettingsStore(suiteName: "CostReportingPeriodTests", userDefaults: defaults)
        #expect(reloaded.costReportingPeriod == .monthToDate)
        reloaded.costUsageHistoryDays = 7
        #expect(reloaded.costReportingPeriod == .rolling(days: 7))
    }

    @Test(arguments: [7, 30, 90, 365]) @MainActor
    func `dashboard migration preserves its range ahead of the menu selection`(days: Int) {
        let defaults = InMemoryUserDefaults(values: [
            "settingsSpendDashboardDays": days,
            CostReportingPeriod.defaultsKey: "month-to-date",
        ])
        let controller = SpendDashboardController(userDefaults: defaults, requestBuilder: { _ in
            fatalError("Persistence-only fixture must not load data")
        })
        #expect(controller.selectedPeriod == (days == 365 ? .allTime : .rolling(days: days)))
        controller.selectPeriod(.monthToDate)
        let reloaded = SpendDashboardController(userDefaults: defaults, requestBuilder: { _ in
            fatalError("Persistence-only fixture must not load data")
        })
        #expect(reloaded.selectedPeriod == .monthToDate)
    }

    @Test
    func `dashboard and CLI sum the same calendar window`() {
        let now = self.date("2026-02-02T20:00:00Z")
        let rows = [
            self.entry("2026-01-31", cost: 100),
            self.entry("2026-02-01", cost: 3),
            self.entry("2026-02-02", cost: 4),
        ]
        let snapshot = CostUsageFetcher.tokenSnapshot(from: .init(data: rows, summary: nil), now: now, historyDays: 90)
        let dashboard = SpendDashboardModel.build(
            inputs: [.init(provider: .codex, displayName: "Synthetic Codex", snapshot: snapshot)],
            requestedDays: 90,
            reportingPeriod: .monthToDate,
            now: now,
            calendar: self.calendar)
        let cliSnapshot = CostUsageFetcher.tokenSnapshot(
            from: .init(data: Array(rows.dropFirst()), summary: nil),
            now: now,
            historyDays: CostReportingPeriod.monthToDate.days(now: now, calendar: self.calendar),
            calendar: self.calendar).reporting(.monthToDate)
        let payload = CodexBarCLI.makeCostPayload(
            provider: .codex,
            snapshot: cliSnapshot,
            error: nil,
            calendar: self.calendar)
        #expect(dashboard.requestedDays == 2)
        #expect(dashboard.groups.first?.totalCost == payload.totals?.totalCostUSD)
        #expect(payload.totals?.totalCostUSD == 7)
        #expect(payload.reportingPeriod == "month-to-date")
        #expect(payload.historyLabel == "Month to date")
        #expect(cliSnapshot.periodLabel == "Month to date")
        #expect(snapshot.summary(forLastDays: dashboard.requestedDays, calendar: self.calendar).totalCostUSD == payload
            .totals?.totalCostUSD)
    }

    @Test
    func `31 day month keeps selected totals and legacy CLI totals distinct`() {
        let now = self.date("2026-01-31T20:00:00Z")
        let source = CostUsageFetcher.tokenSnapshot(
            from: .init(data: [self.entry("2026-01-01", cost: 100), self.entry("2026-01-31", cost: 2)], summary: nil),
            now: now,
            historyDays: 365,
            calendar: self.calendar)
        let selected = source.selecting(.monthToDate, now: now, calendar: self.calendar)
        let payload = CodexBarCLI.makeCostPayload(
            provider: .codex,
            snapshot: selected,
            error: nil,
            calendar: self.calendar)
        #expect(selected.historyDays == 31)
        #expect(selected.last30DaysCostUSD == 102)
        #expect(payload.totals?.totalCostUSD == 102)
        #expect(payload.last30DaysCostUSD == 2)
        #expect(payload.last30DaysTokens == 10)
    }

    @Test(arguments: [false, true])
    func `empty month is zero only for fully scanned history`(partial: Bool) {
        let now = self.date("2026-02-02T20:00:00Z")
        let source = CostUsageFetcher.tokenSnapshot(
            from: .init(data: [self.entry("2026-01-31", cost: 100, requests: 8)], summary: nil),
            now: now,
            historyDays: 90,
            currencyCode: "EUR",
            calendar: self.calendar,
            historyScanIsPartial: partial)
        let selected = source.selecting(.monthToDate, now: now, calendar: self.calendar)
        #expect(selected.daily.isEmpty)
        #expect(selected.last30DaysCostUSD == (partial ? nil : 0))
        #expect(selected.last30DaysTokens == (partial ? nil : 0))
        #expect(selected.sessionCostUSD == (partial ? nil : 0))
        #expect(selected.currencyCode == "EUR")
        #expect(selected.last30DaysRequests == (partial ? nil : 0))
    }

    @Test
    func `cost cache cannot reuse a previous period after a failed refresh`() async {
        let cache = CLIServeResponseCache()
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
        let rolling = CostReportingPeriod.rolling(days: 30).identity(now: now, calendar: calendar)
        let month = CostReportingPeriod.monthToDate.identity(now: now, calendar: calendar)
        _ = await CodexBarCLI.cachedServeResponse(
            key: "cost:codex",
            cache: cache,
            refreshInterval: 300,
            configFingerprint: rolling)
        {
            CLILocalHTTPResponse(status: .ok, body: Data("[{\"provider\":\"codex\",\"last30DaysCostUSD\":100}]".utf8))
        }
        let failed = await CodexBarCLI.cachedServeResponse(
            key: "cost:codex",
            cache: cache,
            refreshInterval: 300,
            configFingerprint: month)
        {
            CLILocalHTTPResponse(
                status: .ok,
                body: Data("[{\"provider\":\"codex\",\"error\":{\"message\":\"synthetic failure\"}}]".utf8))
        }
        #expect(String(data: failed.body, encoding: .utf8)?.contains("synthetic failure") == true)
        #expect(String(data: failed.body, encoding: .utf8)?.contains("last30DaysCostUSD") == false)
    }

    @Test(arguments: [false, true])
    func `request counts preserve unknown daily data`(unknownToday: Bool) {
        let now = self.date("2026-02-02T20:00:00Z")
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: .init(data: [
                self.entry("2026-02-01", cost: 3, requests: unknownToday ? 8 : nil),
                self.entry("2026-02-02", cost: 4, requests: unknownToday ? nil : 4),
            ], summary: nil),
            now: now,
            calendar: self.calendar)
        #expect(snapshot.sessionRequests == (unknownToday ? nil : 4))
        #expect(snapshot.last30DaysRequests == nil)
    }

    @Test
    func `CLI totals coverage uses the selected bucket calendar`() {
        let calendar = CostUsageBucketTimeZone.calendar(identifier: "Asia/Tokyo")
        let now = self.date("2026-02-28T16:00:00Z")
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: .init(data: [self.entry("2026-03-01", cost: 7)], summary: nil),
            now: now,
            historyDays: 1,
            calendar: calendar).reporting(.monthToDate)
        let payload = CodexBarCLI.makeCostPayload(provider: .codex, snapshot: snapshot, error: nil, calendar: calendar)
        #expect(payload.totals?.totalCostUSD == 7)
        #expect(payload.totals?.coverage == payload.coverage)
        #expect(payload.totals?.coverage?.priced == 1)
    }

    private func entry(_ day: String, cost: Double, requests: Int? = nil) -> CostUsageDailyReport.Entry {
        .init(
            date: day,
            inputTokens: 10,
            outputTokens: 0,
            totalTokens: 10,
            requestCount: requests,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }
}
