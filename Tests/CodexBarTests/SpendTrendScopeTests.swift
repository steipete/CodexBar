import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendTrendScopeTests {
    @Test(arguments: ["UTC", "Asia/Shanghai", "America/Los_Angeles"])
    func `daily inspection rejects adjacent dates and days without bars`(zone: String) throws {
        let group = try Self.group(zone: zone)
        let chart = SpendTrendChartModel(group: group, section: .daily, day: nil)
        #expect(try chart.inspectionDate(at: Self.day(30, month: 9, calendar: group.calendar)) == nil)
        #expect(chart.inspectionDate(at: chart.domain.lowerBound.addingTimeInterval(-1)) == nil)
        #expect(chart.inspectionDate(at: chart.domain.upperBound) == nil)
        #expect(try chart.inspectionDate(at: Self.day(4, calendar: group.calendar)) == nil)
        let first = try Self.day(1, calendar: group.calendar)
        #expect(chart.inspectionDate(at: first.addingTimeInterval(12 * 3600)) == first)
        #expect(try chart.inspectionDate(at: Self.day(7, calendar: group.calendar)) == Self.day(
            7,
            calendar: group.calendar))
    }

    @Test
    func `rounded weekly buckets still inspect the in scope amounts they represent`() throws {
        let group = try Self.group(endDay: 31, endMonth: 12)
        let chart = SpendTrendChartModel(group: group, section: .daily, day: nil)
        #expect(chart.unit == .weekOfYear)
        let first = try #require(chart.buckets.first)
        #expect(first.date < chart.scope.lowerBound)
        #expect(chart.inspectionDate(at: first.date) == first.date)
        #expect(try #require(chart.interval(at: first.date)).start == chart.scope.lowerBound)
    }

    @Test
    func `hourly gaps retain missing data inspection within the selected day`() throws {
        let group = try Self.group()
        let day = try Self.day(7, calendar: group.calendar)
        let chart = SpendTrendChartModel(group: group, section: .hourly, day: day)
        let missingHour = day.addingTimeInterval(13 * 3600)
        #expect(chart.bucket(at: missingHour) == nil)
        #expect(chart.inspectionDate(at: missingHour) == missingHour)
        #expect(chart.inspectionDate(at: chart.domain.lowerBound.addingTimeInterval(-1)) == nil)
        #expect(chart.inspectionDate(at: chart.domain.upperBound) == nil)
    }

    @Test
    func `legend keeps recorded zero sources and omits missing or unpriced sources`() throws {
        let group = try Self.group()
        let chart = SpendTrendChartModel(group: group, section: .daily, day: nil)
        #expect(group.providers.count == 6)
        #expect(chart.legendProviders(in: group).map(\.id) == ["native", "opencodex", "cursor", "idle"])
        #expect(chart.total == 17)
        let zero = SpendTrendChartModel(group: group, section: .daily, day: nil, sourceID: "idle")
        #expect(zero.legendProviders(in: group).map(\.id) == ["idle"])
        #expect(zero.buckets.count == 1)
        #expect(zero.total == 0)
        #expect(try zero.inspectionDate(at: Self.day(2, calendar: group.calendar)) == zero.buckets.first?.date)
        let colors = chart.legendProviders(in: group).map {
            SpendChartPalette.color(sourceID: $0.id, provider: $0.provider, providers: group.providers)
        }
        #expect(colors[0] != colors[1])
    }

    @Test
    func `legend follows the displayed day or drilled interval`() throws {
        let group = try Self.group()
        let first = try Self.day(1, calendar: group.calendar)
        let second = try Self.day(2, calendar: group.calendar)
        let drilled = SpendTrendChartModel(
            group: group,
            section: .daily,
            day: nil,
            overviewInterval: DateInterval(start: first, end: second))
        #expect(drilled.legendProviders(in: group).map(\.id) == ["native", "cursor"])
        let hourly = try SpendTrendChartModel(
            group: group,
            section: .hourly,
            day: Self.day(7, calendar: group.calendar))
        #expect(hourly.legendProviders(in: group).map(\.id) == ["native", "opencodex", "idle"])
    }

    @Test
    func `stale global and local focused days resolve to an available in range day`() throws {
        let group = try Self.group(selectedDay: 30, selectedMonth: 9)
        let stale = try Self.day(30, month: 9, calendar: group.calendar)
        let latest = try Self.day(7, calendar: group.calendar)
        #expect(SpendTrendChartModel.hourlyDays(group).count == 2)
        #expect(SpendTrendChartModel.focusedDay(nil, group: group) == latest)
        #expect(SpendTrendChartModel.focusedDay(stale, group: group) == latest)
        let first = try Self.day(1, calendar: group.calendar)
        #expect(SpendTrendChartModel.focusedDay(first.addingTimeInterval(3600), group: group) == first)
    }

    private static func day(_ day: Int, month: Int = 10, calendar: Calendar) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
    }

    static func group(
        zone: String = "Asia/Shanghai",
        endDay: Int = 8,
        endMonth: Int = 10,
        selectedDay: Int? = nil,
        selectedMonth: Int = 10) throws -> SpendDashboardModel.CurrencyGroup
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        let start = try Self.day(1, calendar: calendar)
        let end = try Self.day(endDay, month: endMonth, calendar: calendar)
        let sources: [(String, UsageProvider, Double?, String)] = [
            ("native", .codex, 9, "Codex · #2"), ("opencodex", .codex, 5, "Codex"),
            ("cursor", .cursor, 3, "Cursor"), ("idle", .claude, 0, "Claude"),
            ("unknown", .antigravity, nil, "Antigravity"), ("unused-account", .codex, 0, "Codex · #1"),
        ]
        let providers = sources.enumerated().map { rank, source in
            SpendDashboardModel.ProviderRow(
                id: source.0,
                rank: rank,
                provider: source.1,
                displayName: source.3,
                totalTokens: nil,
                totalCost: source.2,
                coveredDayCount: 7,
                sourceKind: source.0 == "opencodex" ? .openCodex : .native)
        }
        let amounts: [(Int, String, UsageProvider, Double)] = [
            (1, "native", .codex, 2), (1, "cursor", .cursor, 1), (2, "native", .codex, 3),
            (7, "native", .codex, 4), (7, "opencodex", .codex, 5), (7, "cursor", .cursor, 2),
            (2, "idle", .claude, 0),
        ]
        let daily = try amounts.map { day, id, provider, cost in
            try SpendDashboardModel.DailyPoint(
                sourceID: id,
                provider: provider,
                providerName: id,
                day: Self.day(day, calendar: calendar),
                cost: cost,
                stackStart: 0,
                stackEnd: cost)
        }
        let hours: [(Int, String, UsageProvider, Double)] = [
            (30, "native", .codex, 10), (1, "native", .codex, 2), (1, "cursor", .cursor, 1),
            (7, "native", .codex, 4), (7, "opencodex", .codex, 5), (7, "idle", .claude, 0),
        ]
        let hourly = try hours.map { day, id, provider, cost in
            try SpendDashboardModel.HourlyPoint(
                sourceID: id,
                provider: provider,
                providerName: id,
                hour: Self.day(day, month: day == 30 ? 9 : 10, calendar: calendar).addingTimeInterval(9 * 3600),
                cost: cost,
                stackStart: 0,
                stackEnd: cost)
        }
        return try SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: providers,
            models: [],
            dailyPoints: daily,
            totalTokens: nil,
            totalCost: 17,
            coveredDayCount: 7,
            chartDomain: start...end,
            modelHistoryCompleteness: .complete,
            selectedDay: selectedDay.map { try Self.day($0, month: selectedMonth, calendar: calendar) },
            hourlyPoints: hourly,
            timeZone: calendar.timeZone)
    }
}
