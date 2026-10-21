import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendTrendChartTests {
    @Test(arguments: ["zh_CN", "en_US", "de_DE", "ar_SA"])
    func `hour labels retain minutes and a twenty four hour clock across locales`(locale: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: locale)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        for (hour, minute, text) in [(0, 0, "00:00"), (9, 0, "09:00"), (13, 5, "13:05"), (23, 59, "23:59")] {
            let date = try #require(calendar.date(from: DateComponents(
                year: 2026, month: 10, day: 5, hour: hour, minute: minute)))
            #expect(SpendTrendChartModel.clockText(date, calendar: calendar) == text)
            #expect(SpendTrendChartModel.hourText(date, calendar: calendar) == "\(text) UTC+08:00")
        }
    }

    @Test(arguments: [("UTC", "UTC"), ("Asia/Kolkata", "UTC+05:30"), ("America/St_Johns", "UTC-03:30")])
    func `hour labels use the reporting zone and retain fractional UTC offsets`(
        zone: String, offset: String) throws
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 9)))
        #expect(SpendTrendChartModel.hourText(date, calendar: calendar) == "09:00 \(offset)")
    }

    @Test(arguments: [nil, "unpriced"] as [String?])
    func `priced chart records never become a complete total when another record is unpriced`(
        sourceID: String?) throws
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 18)))
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [("2026-10-04", 1.0 as Double?), ("2026-10-05", nil)].map { date, cost in
                CostUsageDailyReport.Entry(
                    date: date,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    costUSD: cost,
                    modelsUsed: nil,
                    modelBreakdowns: nil)
            },
            updatedAt: now)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(id: "unpriced", provider: .codex, displayName: "Demo account", snapshot: snapshot)],
            requestedDays: 14,
            now: now,
            calendar: calendar).groups.first)
        // A single source with an unknown total does not set the mixed-source partial-cost flag.
        #expect(group.totalCost == nil)
        #expect(group.providers.first?.totalCost == nil)
        #expect(!group.hasPartialCost)
        let chart = SpendTrendChartModel(group: group, section: .daily, day: nil, sourceID: sourceID)
        #expect(chart.total == 1)
        #expect(chart.buckets.count == 1)
        #expect(chart.recordedSpendLabel == "Recorded spend")
    }

    @Test
    func `hourly view focuses on the latest day without dropping history from the model`() throws {
        let group = try self.group()
        let day = try #require(SpendTrendChartModel.focusedDay(nil, group: group))
        let model = SpendTrendChartModel(group: group, section: .hourly, day: day)
        #expect(model.buckets.count == 2)
        #expect(model.total == 12)
        #expect(group.hourlyPoints.count == 6)
        #expect(model.domain.lowerBound == day)
        #expect(model.domain.upperBound.timeIntervalSince(day) == 86400)
    }

    @Test
    func `isolating an account restacks at zero and preserves its exact costs`() throws {
        let group = try self.group()
        let model = SpendTrendChartModel(group: group, section: .daily, day: nil, sourceID: "b")
        #expect(model.segments.count == 2)
        #expect(model.segments.allSatisfy { $0.start == 0 && $0.end == $0.cost })
        #expect(model.total == 8)
        #expect(model.buckets.map(\.total) == [2, 6])
    }

    @Test(arguments: [0.0, 1.0])
    func `missing hours stay distinct from recorded zero and positive amounts`(lateHourCost: Double) throws {
        let group = try self.group(lateHourCost: lateHourCost)
        let day = try #require(SpendTrendChartModel.focusedDay(nil, group: group))
        let model = SpendTrendChartModel(group: group, section: .hourly, day: day)
        #expect(model.bucket(at: day.addingTimeInterval(11 * 3600)) == nil)
        #expect(model.bucket(at: day.addingTimeInterval(9 * 3600 + 30 * 60))?.total == 10)
        #expect(model.bucket(at: day.addingTimeInterval(14 * 3600))?.total == lateHourCost * 2)
    }

    @Test
    func `changing filters resolves a stale focused day to a day with available data`() throws {
        let group = try self.group()
        let stale = group.chartDomain.lowerBound.addingTimeInterval(-86400)
        #expect(SpendTrendChartModel.focusedDay(stale, group: group) == SpendTrendChartModel.hourlyDays(group).last)
        #expect(SpendTrendChartModel.hourlyDays(group).count == 2)
    }

    @Test
    func `same name accounts remain distinct in the stack and legend`() throws {
        let group = try self.group()
        let model = SpendTrendChartModel(group: group, section: .daily, day: nil)
        #expect(model.segments.count == 4)
        #expect(model.total == 14)
        let labels = group.providers.map { SpendChartPalette.label($0, providers: group.providers) }
        #expect(Set(labels).count == 2)
        let first = SpendChartPalette.color(sourceID: "a", provider: .codex, providers: group.providers)
        let second = SpendChartPalette.color(sourceID: "b", provider: .codex, providers: group.providers)
        #expect(first != second)
        #expect(first == SpendChartPalette.color(
            sourceID: "a",
            provider: .codex,
            providers: group.providers.reversed()))
    }

    @Test(arguments: [23, 25])
    func `hourly domains respect daylight saving and retain repeated hours`(hours: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let day = try #require(calendar.date(from: DateComponents(
            year: 2026, month: hours == 23 ? 3 : 11, day: hours == 23 ? 8 : 1)))
        let interval = try #require(calendar.dateInterval(of: .day, for: day))
        let points = (0..<hours).map { index in
            SpendDashboardModel.HourlyPoint(
                sourceID: "a",
                provider: .codex,
                providerName: "Codex",
                hour: day.addingTimeInterval(Double(index) * 3600),
                cost: 1,
                stackStart: 0,
                stackEnd: 1)
        }
        let group = SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: [],
            models: [],
            dailyPoints: [],
            totalTokens: nil,
            totalCost: nil,
            coveredDayCount: 1,
            chartDomain: day...interval.end,
            modelHistoryCompleteness: .complete,
            hourlyPoints: points,
            timeZone: calendar.timeZone)
        let model = SpendTrendChartModel(group: group, section: .hourly, day: day)
        #expect(model.domain.upperBound.timeIntervalSince(day) == Double(hours) * 3600)
        #expect(model.buckets.count == hours)
        #expect(model.hourlyTicks.map { model.hourlyAxisText($0) }
            == ["00:00", "04:00", "08:00", "12:00", "16:00", "20:00", "24:00"])
        #expect(model.hourlyTicks.last == interval.end)
        #expect(model.hourlyTimeZoneText == (hours == 23 ? "UTC-08:00 → UTC-07:00" : "UTC-07:00 → UTC-08:00"))
        if hours == 25 {
            #expect(SpendTrendChartModel.hourText(points[1].hour, calendar: calendar) == "01:00 UTC-07:00")
            #expect(SpendTrendChartModel.hourText(points[2].hour, calendar: calendar) == "01:00 UTC-08:00")
        }
        for point in points {
            #expect(model.bucket(at: point.hour.addingTimeInterval(1800))?.date == point.hour)
            #expect(model.inspectionDate(at: point.hour.addingTimeInterval(1800)) == point.hour)
        }
    }

    @Test(arguments: [90, 365])
    func `long ranges aggregate without losing source costs`(days: Int) throws {
        let group = try self.group(days: days)
        let model = SpendTrendChartModel(group: group, section: .daily, day: nil)
        #expect(model.unit == (days > 180 ? .month : .weekOfYear))
        #expect(!model.needsScrolling)
        #expect(model.total == 14)
        #expect(model.buckets.count == 1)
        #expect(model.segments.map(\.cost) == [6, 8])
        #expect(model.segments.map(\.start) == [0, 6])
        #expect(model.segments.map(\.end) == [6, 14])
        let isolated = SpendTrendChartModel(group: group, section: .daily, day: nil, sourceID: "b")
        #expect(isolated.total == 8)
        #expect(isolated.segments.first?.start == 0)
        let day = try #require(SpendTrendChartModel.focusedDay(nil, group: group))
        let interval = try #require(model.interval(at: day))
        let drilled = SpendTrendChartModel(group: group, section: .daily, day: nil, overviewInterval: interval)
        #expect(drilled.unit == .day)
        #expect(drilled.buckets.count == 2)
        #expect(drilled.total == 14)
        #expect(drilled.scope.upperBound <= group.chartDomain.upperBound)
    }

    @Test
    func `partial periods exclude out of scope days from totals and drill down`() throws {
        let group = try self.group(days: 90)
        let day = try #require(SpendTrendChartModel.focusedDay(nil, group: group))
        let end = try #require(group.calendar.date(byAdding: .day, value: 1, to: day))
        let interval = DateInterval(start: day, end: end)
        let model = SpendTrendChartModel(group: group, section: .daily, day: nil, overviewInterval: interval)
        #expect(model.total == 10)
        #expect(model.buckets.count == 1)
        #expect(model.interval(at: day) == interval)
        #expect(model.interval(at: day.addingTimeInterval(-86400)) == nil)
    }

    @Test
    func `hourly nil focus resolves latest day and does not return daily buckets`() throws {
        let group = try self.group()
        let model = SpendTrendChartModel(group: group, section: .hourly, day: nil)
        #expect(model.unit == .hour)
        #expect(model.total == 12)
        #expect(model.buckets.count == 2)
    }

    @Test(arguments: [90, 365])
    func `calendar boundaries assign every daily amount to exactly one overview bucket`(days: Int) throws {
        let fixture = try self.group(days: days)
        let dates = [(9, 30), (10, 1), (10, 4), (10, 5)]
        let points = try dates.enumerated().map { index, components in
            try SpendDashboardModel.DailyPoint(
                sourceID: index.isMultiple(of: 2) ? "a" : "b",
                provider: .codex,
                providerName: "Codex",
                day: #require(fixture.calendar.date(from: DateComponents(
                    year: 2026, month: components.0, day: components.1))),
                cost: Double(index + 1),
                stackStart: 0,
                stackEnd: Double(index + 1))
        }
        let group = SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: fixture.providers,
            models: [],
            dailyPoints: points,
            totalTokens: nil,
            totalCost: 10,
            coveredDayCount: days,
            chartDomain: fixture.chartDomain,
            modelHistoryCompleteness: .complete,
            timeZone: fixture.timeZone)
        let model = SpendTrendChartModel(group: group, section: .daily, day: nil)
        #expect(model.buckets.count == 2)
        #expect(model.total == 10)
        #expect(model.buckets.map(\.total) == (days == 365 ? [1, 9] : [3, 7]))
        for point in points {
            let interval = try #require(model.interval(at: point.day))
            #expect(interval.start <= point.day && point.day < interval.end)
            let drilled = SpendTrendChartModel(group: group, section: .daily, day: nil, overviewInterval: interval)
            #expect(drilled.total == model.bucket(at: point.day)?.total)
        }
    }

    private func group(days: Int = 14, lateHourCost: Double = 1) throws -> SpendDashboardModel.CurrencyGroup {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 18)))
        let day = calendar.startOfDay(for: now)
        let previous = try #require(calendar.date(byAdding: .day, value: -1, to: day))
        let inputs = ["a", "b"].enumerated().map { index, id in
            let costs = index == 0 ? [2.0, 4] : [2.0, 6]
            let daily = zip(["2026-10-04", "2026-10-05"], costs).map { date, cost in
                CostUsageDailyReport.Entry(
                    date: date,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 100,
                    costUSD: cost,
                    modelsUsed: nil,
                    modelBreakdowns: nil)
            }
            let hourly = [
                CostUsageHourlyEntry(hour: previous.addingTimeInterval(9 * 3600), totalTokens: 100, costUSD: costs[0]),
                CostUsageHourlyEntry(hour: day.addingTimeInterval(9 * 3600), totalTokens: 100, costUSD: costs[1]),
                CostUsageHourlyEntry(hour: day.addingTimeInterval(14 * 3600), totalTokens: 100, costUSD: lateHourCost),
            ]
            let snapshot = CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 200,
                last30DaysCostUSD: costs.reduce(0, +),
                daily: daily,
                hourly: hourly,
                updatedAt: now)
            return SpendDashboardModel.ProviderInput(id: id, provider: .codex, displayName: "Codex", snapshot: snapshot)
        }
        return try #require(SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: days,
            now: now,
            calendar: calendar).groups.first)
    }
}
