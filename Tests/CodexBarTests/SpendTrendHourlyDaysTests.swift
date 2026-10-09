import CodexBarCore
import Darwin
import Foundation
import Testing
@testable import CodexBar

struct SpendTrendHourlyDaysTests {
    @Test
    func `populating navigation leaves group equality and returned value semantics unchanged`() throws {
        let start = try Self.date("2026-10-01T00:00:00Z")
        let points = [Self.point(start), Self.point(start.addingTimeInterval(86400))]
        let bounds = start...start.addingTimeInterval(2 * 86400)
        let original = Self.group(points: points, bounds: bounds)
        let rebuilt = Self.group(points: points, bounds: bounds)
        #expect(original == rebuilt)
        var days = SpendTrendChartModel.hourlyDays(original)
        days.removeLast()
        #expect(original == rebuilt)
        #expect(SpendTrendChartModel.hourlyDays(original).count == 2)
        #expect(SpendTrendChartModel.hourlyDays(rebuilt).count == 2)
        #expect(original == rebuilt)
    }

    @Test
    func `concurrent first reads and group copies share one navigation array`() async throws {
        let start = try Self.date("2026-10-01T00:00:00Z")
        let group = Self.group(
            points: [Self.point(start), Self.point(start.addingTimeInterval(86400))],
            bounds: start...start.addingTimeInterval(2 * 86400))
        let results = await withTaskGroup(of: [Date].self) { tasks in
            for _ in 0..<16 {
                tasks.addTask { SpendTrendChartModel.hourlyDays(group) }
            }
            var results: [[Date]] = []
            for await dates in tasks {
                results.append(dates)
            }
            return results
        }
        let first = try #require(results.first)
        for dates in results {
            #expect(dates.count == 2)
            first.withUnsafeBufferPointer { lhs in
                dates.withUnsafeBufferPointer { rhs in
                    #expect(lhs.baseAddress == rhs.baseAddress)
                }
            }
        }
    }

    @Test
    @MainActor
    func `synthetic navigation benchmark`() throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_HOURLY_DAYS_BENCHMARK"] == "1" else { return }
        let start = try Self.date("2025-10-06T00:00:00Z")
        let points = (0..<35020).map { index in
            Self.point(start.addingTimeInterval(Double(index / 4) * 3600), sourceID: "demo-\(index % 4)")
        }
        let bounds = start...start.addingTimeInterval(365 * 86400)
        let group = Self.group(points: points, bounds: bounds)
        func measure(iterations: Int, read: () -> [Date]) -> [String: Double] {
            let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let wall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            var count = 0
            for _ in 0..<iterations {
                count += read().count
            }
            let cpuMS = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1_000_000
            let wallMS = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - wall) / 1_000_000
            #expect(count == iterations * 365)
            return ["cpu_ms": cpuMS, "wall_ms": wallMS]
        }
        /// Retain the original main implementation as the reference, including its per-point calendar.
        func baseline() -> [Date] {
            Set(group.hourlyPoints.filter {
                $0.hour >= group.chartDomain.lowerBound && $0.hour < group.chartDomain.upperBound
            }.map { group.calendar.startOfDay(for: $0.hour) }).sorted()
        }
        let cold = measure(iterations: 1) { SpendTrendChartModel.hourlyDays(group) }
        #expect(SpendTrendChartModel.hourlyDays(group) == baseline())
        var records: [[String: Any]] = []
        for cached in [false, true, true, false] {
            records.append([
                "cached": cached,
                "iterations": 15,
                "duration": measure(iterations: 15) {
                    cached ? SpendTrendChartModel.hourlyDays(group) : baseline()
                },
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "points": points.count, "days": 365, "synthetic_only": true,
            "main_thread": Thread.isMainThread, "cold_read": cold, "reads": records,
        ], options: [.sortedKeys])
        let json = try #require(String(data: data, encoding: .utf8))
        print("HOURLY_DAYS_BENCHMARK \(json)")
    }

    @Test
    func `repeated navigation shares the immutable date array`() throws {
        let start = try Self.date("2025-10-06T00:00:00Z")
        let points = (0..<35020).map { index in
            Self.point(start.addingTimeInterval(Double(index / 4) * 3600), sourceID: "demo-\(index % 4)")
        }
        let group = Self.group(points: points, bounds: start...start.addingTimeInterval(365 * 86400))
        let first = SpendTrendChartModel.hourlyDays(group)
        let second = SpendTrendChartModel.hourlyDays(group)
        #expect(first.count == 365)
        first.withUnsafeBufferPointer { lhs in
            second.withUnsafeBufferPointer { rhs in
                #expect(lhs.baseAddress == rhs.baseAddress)
            }
        }
    }

    @Test
    func `empty hourly history has no navigable or focused day`() throws {
        let start = try Self.date("2026-10-01T00:00:00Z")
        let group = Self.group(points: [], bounds: start...start.addingTimeInterval(86400), selectedDay: start)
        #expect(SpendTrendChartModel.hourlyDays(group).isEmpty)
        #expect(SpendTrendChartModel.focusedDay(start, group: group) == nil)
    }

    @Test
    func `navigation sorts distinct recorded days within the half open reporting range`() throws {
        let first = try Self.date("2026-10-01T00:00:00Z")
        let second = first.addingTimeInterval(86400)
        let end = second.addingTimeInterval(86400)
        let group = Self.group(
            points: [
                Self.point(second.addingTimeInterval(3600)),
                Self.point(end),
                Self.point(first, sourceID: "demo-b", cost: 0),
                Self.point(first.addingTimeInterval(-1)),
                Self.point(second.addingTimeInterval(7200), sourceID: "demo-b"),
                Self.point(first.addingTimeInterval(3600)),
            ],
            bounds: first...end,
            selectedDay: first)

        #expect(SpendTrendChartModel.hourlyDays(group) == [first, second])
        #expect(SpendTrendChartModel.focusedDay(nil, group: group) == first)
        #expect(SpendTrendChartModel.focusedDay(end, group: Self.group(
            points: group.hourlyPoints, bounds: first...end)) == second)
    }

    @Test(arguments: [
        ("America/Los_Angeles", 2026, 3, 8, 23.0),
        ("America/Los_Angeles", 2026, 11, 1, 25.0),
        ("Australia/Lord_Howe", 2026, 4, 5, 24.5),
        ("Australia/Lord_Howe", 2026, 10, 4, 23.5),
        ("America/Sao_Paulo", 2018, 11, 4, 23.0),
    ])
    func `navigation retains one date across daylight saving transitions`(
        zone: String, year: Int, month: Int, day: Int, hours: Double) throws
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        let noon = try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
        let start = calendar.startOfDay(for: noon)
        let end = try calendar.startOfDay(for: #require(calendar.date(byAdding: .day, value: 1, to: noon)))
        #expect(end.timeIntervalSince(start) == hours * 3600)
        let group = Self.group(
            points: [Self.point(start), Self.point(end.addingTimeInterval(-1800)), Self.point(end)],
            bounds: start...end,
            timeZone: calendar.timeZone)

        #expect(SpendTrendChartModel.hourlyDays(group) == [start])
        #expect(SpendTrendChartModel.focusedDay(nil, group: group) == start)
    }

    @Test
    func `a new time zone derives new dates from the same instants`() throws {
        let bounds = try Self.date("2026-10-01T00:00:00Z")...Self.date("2026-10-04T00:00:00Z")
        let points = try ["2026-10-02T00:30:00Z", "2026-10-02T07:30:00Z"].map {
            try Self.point(Self.date($0))
        }
        let pacific = try Self.group(
            points: points, bounds: bounds, timeZone: #require(TimeZone(identifier: "America/Los_Angeles")))
        let shanghai = try Self.group(
            points: points, bounds: bounds, timeZone: #require(TimeZone(identifier: "Asia/Shanghai")))

        #expect(try SpendTrendChartModel.hourlyDays(pacific) == [
            Self.date("2026-10-01T07:00:00Z"), Self.date("2026-10-02T07:00:00Z"),
        ])
        #expect(try SpendTrendChartModel.hourlyDays(shanghai) == [Self.date("2026-10-01T16:00:00Z")])
        #expect(SpendTrendChartModel.hourlyDays(pacific).count == 2)
    }

    @Test
    func `rebuilt models follow range selection hidden sources and replaced account history`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let first = try Self.date("2026-10-01T00:00:00Z")
        let second = first.addingTimeInterval(86400)
        let third = second.addingTimeInterval(86400)
        let now = third.addingTimeInterval(12 * 3600)
        let a = Self.input(id: "demo-a", day: "2026-10-01", hour: first.addingTimeInterval(3600), now: now)
        let b = Self.input(id: "demo-b", day: "2026-10-03", hour: third.addingTimeInterval(3600), now: now)
        func build(
            inputs: [SpendDashboardModel.ProviderInput] = [a, b],
            period: CostReportingPeriod = .allTime,
            hidden: Set<String> = [],
            selectedDay: Date? = nil) throws -> SpendDashboardModel.CurrencyGroup
        {
            try #require(SpendDashboardModel.build(
                inputs: inputs,
                reportingPeriod: period,
                now: now,
                calendar: calendar,
                hiddenSourceIDs: hidden,
                selectedDay: selectedDay).groups.first)
        }
        let original = try build()
        #expect(SpendTrendChartModel.hourlyDays(original) == [first, third])
        #expect(try SpendTrendChartModel.hourlyDays(build(period: .rolling(days: 1))) == [third])
        #expect(try SpendTrendChartModel.hourlyDays(build(hidden: [b.id])) == [first])
        #expect(try SpendTrendChartModel.hourlyDays(build(selectedDay: third)) == [third])
        #expect(try SpendTrendChartModel.hourlyDays(build(selectedDay: second)).isEmpty)
        let replacement = Self.input(id: a.id, day: "2026-10-02", hour: second.addingTimeInterval(3600), now: now)
        #expect(try SpendTrendChartModel.hourlyDays(build(inputs: [replacement])) == [second])
        #expect(try SpendTrendChartModel.hourlyDays(build()) == [first, third])
        #expect(SpendTrendChartModel.hourlyDays(original) == [first, third])
    }

    @Test
    func `partial history keeps recorded zero hours without inventing dates for unpriced hours`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let first = try Self.date("2026-10-01T00:00:00Z")
        let second = first.addingTimeInterval(86400)
        let now = second.addingTimeInterval(12 * 3600)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [Self.entry("2026-10-01", cost: 0), Self.entry("2026-10-02", cost: nil)],
            hourly: [
                CostUsageHourlyEntry(hour: first.addingTimeInterval(3600), totalTokens: nil, costUSD: 0),
                CostUsageHourlyEntry(hour: second.addingTimeInterval(3600), totalTokens: nil, costUSD: nil),
            ],
            updatedAt: now)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(id: "demo-partial", provider: .codex, displayName: "Demo account", snapshot: snapshot)],
            reportingPeriod: .allTime,
            now: now,
            calendar: calendar).groups.first)

        #expect(group.totalCost == nil)
        #expect(group.hourlyPoints.map(\.cost) == [0])
        #expect(SpendTrendChartModel.hourlyDays(group) == [first])
        #expect(SpendTrendChartModel.focusedDay(second, group: group) == first)
    }

    private static func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    private static func point(
        _ hour: Date, sourceID: String = "demo-a", cost: Double = 1) -> SpendDashboardModel.HourlyPoint
    {
        SpendDashboardModel.HourlyPoint(
            sourceID: sourceID,
            provider: .codex,
            providerName: "Demo account",
            hour: hour,
            cost: cost,
            stackStart: 0,
            stackEnd: cost)
    }

    private static func group(
        points: [SpendDashboardModel.HourlyPoint],
        bounds: ClosedRange<Date>,
        selectedDay: Date? = nil,
        timeZone: TimeZone = .gmt) -> SpendDashboardModel.CurrencyGroup
    {
        SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: [],
            models: [],
            dailyPoints: [],
            totalTokens: nil,
            totalCost: nil,
            coveredDayCount: 0,
            chartDomain: bounds,
            modelHistoryCompleteness: .incomplete,
            selectedDay: selectedDay,
            hourlyPoints: points,
            timeZone: timeZone)
    }

    private static func input(
        id: String, day: String, hour: Date, now: Date) -> SpendDashboardModel.ProviderInput
    {
        SpendDashboardModel.ProviderInput(
            id: id,
            provider: .codex,
            displayName: "Demo account",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                daily: [self.entry(day, cost: 1)],
                hourly: [CostUsageHourlyEntry(hour: hour, totalTokens: nil, costUSD: 1)],
                updatedAt: now))
    }

    private static func entry(_ day: String, cost: Double?) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }
}
