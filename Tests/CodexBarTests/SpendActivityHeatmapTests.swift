import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendActivityHeatmapTests {
    @Test
    func `daily levels keep exact boundaries and tolerate Int max`() {
        #expect(SpendActivityLevels.dailyLevels([0, 1, 25, 26, 50, 51, 75, 76, 100]) == [
            0, 1, 1, 2, 2, 3, 3, 4, 4,
        ])
        #expect(SpendActivityLevels.dailyLevels([Int.max, Int.max / 2]) == [4, 2])
    }

    @Test
    func `weekly and cumulative totals saturate instead of overflowing`() throws {
        let calendar = Self.calendar
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 2)))
        let now = try #require(calendar.date(byAdding: .day, value: 7, to: start))
        let daily = [Int.max, 1, 0, 0, 0, 0, 0, 2]
        let points = try daily.enumerated().map { offset, tokens in
            let day = try #require(calendar.date(byAdding: .day, value: offset, to: start))
            return SpendDashboardModel.TokenActivityPoint(day: day, totalTokens: tokens)
        }
        let series = SpendActivitySeries.make(from: points, now: now, calendar: calendar)
        let weekly = series.weeklyActivity()
        #expect(Array(weekly.values.suffix(2)) == [Int.max, 2])
        #expect(Array(weekly.cumulative().values.suffix(2)) == [Int.max, Int.max])
    }

    @Test
    func `series uses a Sunday aligned 53 week container for exactly 365 visible days`() throws {
        let calendar = Self.calendar
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 5)))
        let previousDay = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        let futureDay = try #require(calendar.date(byAdding: .day, value: 1, to: now))
        let series = SpendActivitySeries.make(
            from: [
                .init(day: previousDay, totalTokens: 10),
                .init(day: now, totalTokens: 20),
                .init(day: futureDay, totalTokens: 30),
            ],
            now: now,
            calendar: calendar)

        #expect(series.daily.count == 53 * 7)
        #expect(series.isCovered.count == 53 * 7)
        #expect(calendar.component(.weekday, from: series.start) == 1)
        #expect(series.visibleDayCount == 365)
        #expect(series.daily.reduce(0, +) == 30)
        #expect(series.coveredDayCount == 2)
        #expect(series.date(at: series.daily.count - 1)! > series.today)
    }

    @Test(arguments: Array(2...8))
    func `oldest annual day remains visible for every ending weekday`(augustDay: Int) throws {
        let calendar = Self.calendar
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: augustDay)))
        let rangeStart = try #require(calendar.date(
            byAdding: .day,
            value: -(SpendActivitySeries.rangeDayCount - 1),
            to: now))
        let points = try (0..<SpendActivitySeries.rangeDayCount).map { offset in
            let day = try #require(calendar.date(byAdding: .day, value: offset, to: rangeStart))
            return SpendDashboardModel.TokenActivityPoint(day: day, totalTokens: offset == 0 ? 1 : 0)
        }
        let series = SpendActivitySeries.make(from: points, now: now, calendar: calendar)
        let visibleIndices = series.daily.indices.filter(series.isVisible)

        #expect(series.visibleDayCount == SpendActivitySeries.rangeDayCount)
        #expect(series.coveredDayCount == SpendActivitySeries.rangeDayCount)
        #expect(series.daily.reduce(0, +) == 1)
        #expect(visibleIndices.first.flatMap(series.date(at:)) == rangeStart)
        #expect(visibleIndices.last.flatMap(series.date(at:)) == now)
    }

    @Test(arguments: [6, 7, 11, 12, 13])
    func `annual coverage survives midnight daylight saving transitions`(septemberDay: Int) throws {
        var calendar = Self.calendar
        calendar.timeZone = try #require(TimeZone(identifier: "America/Santiago"))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: septemberDay,
            hour: 12)))
        let points = try (0..<SpendActivitySeries.rangeDayCount).map { offset in
            let date = try #require(calendar.date(byAdding: .day, value: -offset, to: now))
            return SpendDashboardModel.TokenActivityPoint(
                day: calendar.startOfDay(for: date),
                totalTokens: offset + 1)
        }
        let series = SpendActivitySeries.make(from: points, now: now, calendar: calendar)
        let visibleIndices = series.daily.indices.filter(series.isVisible)

        #expect(series.visibleDayCount == 365)
        #expect(series.coveredDayCount == 365)
        #expect(series.daily.reduce(0, +) == (1...365).reduce(0, +))
        #expect(visibleIndices.first.flatMap(series.date(at:)) == points.last?.day)
        #expect(visibleIndices.last.flatMap(series.date(at:)) == points.first?.day)
        for index in visibleIndices {
            let date = try #require(series.date(at: index))
            #expect(date == calendar.startOfDay(for: date))
            #expect(series.daily[index] == points.first { $0.day == date }?.totalTokens)
        }
        let weekly = series.weeklyActivity()
        #expect(weekly.isCovered.count(where: { $0 }) == weekly.isScanned.count(where: { $0 }))
        #expect(weekly.cumulative().isCovered.last == true)
    }

    @Test
    func `midnight daylight saving preserves unscanned days and scanned gaps`() throws {
        var calendar = Self.calendar
        calendar.timeZone = try #require(TimeZone(identifier: "America/Santiago"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 12)))
        let points = try (0..<365).map { offset in
            let date = try #require(calendar.date(byAdding: .day, value: -offset, to: now))
            return SpendDashboardModel.TokenActivityPoint(
                day: calendar.startOfDay(for: date),
                totalTokens: offset >= 30 || offset == 10 ? nil : 1,
                isScanned: offset < 30)
        }
        let series = SpendActivitySeries.make(from: points, now: now, calendar: calendar)
        for point in points {
            let index = try #require(series.daily.indices.first { series.date(at: $0) == point.day })
            #expect(series.isScanned[index] == point.isScanned)
            #expect(series.isCovered[index] == (point.totalTokens != nil))
        }
        #expect(series.coveredDayCount == 29)
        let weekly = series.weeklyActivity()
        let firstScannedWeek = try #require(weekly.isScanned.firstIndex(of: true))
        let cumulative = weekly.cumulative()
        #expect(cumulative.isCovered[firstScannedWeek])
        #expect(cumulative.isCovered.last == false)
    }

    @Test
    func `mixed provider activity unions available sources per day`() throws {
        let now = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 16)))
        let oldDay = "2025-08-01"
        let annual = Self.snapshot(
            entries: [
                Self.entry(day: oldDay, cost: 2, tokens: 40),
                Self.entry(day: "2026-07-16", cost: 3, tokens: 10),
            ],
            historyDays: 365,
            last30DaysTokens: 50)
        let recent = Self.snapshot(
            entries: [
                Self.entry(day: "2026-07-16", cost: 1, tokens: 60),
            ],
            historyDays: 30,
            last30DaysTokens: 60)
        let model = SpendDashboardModel.build(
            inputs: [
                .init(id: "annual", provider: .claude, displayName: "Claude", snapshot: annual),
                .init(id: "recent", provider: .openai, displayName: "OpenAI", snapshot: recent),
            ],
            requestedDays: 30,
            now: now,
            calendar: Self.calendar)

        let oldDate = try #require(Self.calendar.date(from: DateComponents(year: 2025, month: 8, day: 1)))
        #expect(model.tokenActivity.count == SpendDashboardModel.tokenActivityDayCount)
        #expect(model.tokenActivity.first { $0.day == oldDate }?.totalTokens == 40)
        #expect(model.tokenActivity.first { $0.day == now }?.totalTokens == 70)
        #expect(model.groups.first?.dailyPoints.allSatisfy { $0.day == now } == true)
    }

    @Test
    func `token activity unions partial provider coverage instead of requiring every source`() throws {
        let now = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 16)))
        let recent = Self.snapshot(
            entries: [Self.entry(day: "2026-07-16", cost: 1, tokens: 40)],
            historyDays: 30,
            last30DaysTokens: 40)
        let unavailable = Self.snapshot(
            entries: [],
            historyDays: 30,
            last30DaysTokens: nil,
            historyCoverageIsEstablished: false)
        let model = SpendDashboardModel.build(
            inputs: [
                .init(id: "recent", provider: .claude, displayName: "Claude", snapshot: recent),
                .init(id: "missing", provider: .openai, displayName: "OpenAI", snapshot: unavailable),
            ],
            requestedDays: 30,
            now: now,
            calendar: Self.calendar)

        let coveredDays = model.tokenActivity.count(where: { $0.totalTokens != nil })
        #expect(coveredDays > 0)
        #expect(model.tokenActivity.first { $0.day == now }?.totalTokens == 40)
    }

    @Test
    func `scanned provider with unresolved day preserves gap even if other providers have tokens`() throws {
        let now = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 16)))
        let valid = Self.snapshot(
            entries: [Self.entry(day: "2026-07-16", cost: 1, tokens: 40)],
            historyDays: 30,
            last30DaysTokens: 40)
        let scannedWithInvalidDay = Self.snapshot(
            entries: [Self.entry(day: "2026-07-16", cost: 1, tokens: -5)],
            historyDays: 30,
            last30DaysTokens: 10)
        let model = SpendDashboardModel.build(
            inputs: [
                .init(id: "valid", provider: .claude, displayName: "Claude", snapshot: valid),
                .init(id: "invalid", provider: .openai, displayName: "OpenAI", snapshot: scannedWithInvalidDay),
            ],
            requestedDays: 30,
            now: now,
            calendar: Self.calendar)

        let point = model.tokenActivity.first { $0.day == now }
        #expect(point?.totalTokens == nil)
        #expect(point?.isScanned == true)
    }

    @Test
    func `OpenCode Go token history keeps shared activity days covered`() throws {
        let now = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 12)))
        let today = Self.calendar.startOfDay(for: now)
        let yesterday = try #require(Self.calendar.date(byAdding: .day, value: -1, to: today))
        let openCodeGo = OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: true,
            rollingUsagePercent: 0,
            weeklyUsagePercent: 0,
            monthlyUsagePercent: 0,
            rollingResetInSec: 0,
            weeklyResetInSec: 0,
            monthlyResetInSec: 0,
            daily: [Self.entry(day: "2026-07-16", cost: 2, tokens: 60)],
            updatedAt: now).toCostUsageTokenSnapshot(historyDays: 30)
        let claude = Self.snapshot(
            entries: [
                Self.entry(day: "2026-07-15", cost: 1, tokens: 15),
                Self.entry(day: "2026-07-16", cost: 1, tokens: 40),
            ],
            historyDays: 30,
            last30DaysTokens: 55)
        let model = SpendDashboardModel.build(
            inputs: [
                .init(id: "claude", provider: .claude, displayName: "Claude", snapshot: claude),
                .init(id: "opencodego", provider: .opencodego, displayName: "OpenCode Go", snapshot: openCodeGo),
            ],
            requestedDays: 30,
            now: now,
            calendar: Self.calendar)

        #expect(model.tokenActivity.first { $0.day == today }?.totalTokens == 100)
        #expect(model.tokenActivity.first { $0.day == yesterday }?.totalTokens == 15)
    }

    @Test
    func `covered empty history is zero while unestablished history remains unavailable`() throws {
        let now = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 16)))
        let covered = SpendDashboardModel.build(
            inputs: [
                .init(
                    provider: .claude,
                    displayName: "Claude",
                    snapshot: Self.snapshot(entries: [], historyDays: 365, last30DaysTokens: 0)),
            ],
            requestedDays: 30,
            now: now,
            calendar: Self.calendar)
        let unavailable = SpendDashboardModel.build(
            inputs: [
                .init(
                    provider: .claude,
                    displayName: "Claude",
                    snapshot: Self.snapshot(
                        entries: [],
                        historyDays: 365,
                        last30DaysTokens: nil,
                        historyCoverageIsEstablished: false)),
            ],
            requestedDays: 30,
            now: now,
            calendar: Self.calendar)

        #expect(covered.tokenActivity.allSatisfy { $0.totalTokens == 0 })
        #expect(unavailable.tokenActivity.allSatisfy { $0.totalTokens == nil })
    }

    @Test
    func `shared cache activity uses its wider partial coverage without widening spend`() throws {
        let now = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 16)))
        let oldDay = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 5, day: 1)))
        let snapshot = Self.snapshot(
            entries: [Self.entry(day: "2026-07-16", cost: 2, tokens: 10)],
            historyDays: 30,
            last30DaysTokens: 10)
        let cache = CostUsageTokenActivityCache(
            daily: [
                Self.entry(day: "2026-05-01", cost: nil, tokens: 40),
                Self.entry(day: "2026-07-16", cost: nil, tokens: 10),
            ],
            coverageSinceKey: "2026-05-01",
            coverageUntilKey: "2026-07-16")
        let model = SpendDashboardModel.build(
            inputs: [
                .init(
                    provider: .codex,
                    displayName: "Codex",
                    snapshot: snapshot,
                    tokenActivityCache: cache),
            ],
            requestedDays: 30,
            now: now,
            calendar: Self.calendar)

        #expect(model.requestedDays == 30)
        #expect(model.groups.first?.dailyPoints.map(\.day) == [now])
        #expect(model.tokenActivity.first { $0.day == oldDay }?.totalTokens == 40)
    }

    @Test
    func `empty shared cache marks only its partial range as confirmed zero`() throws {
        let now = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 16)))
        let beforeCoverage = try #require(Self.calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 13)))
        let cache = CostUsageTokenActivityCache(
            daily: [],
            coverageSinceKey: "2026-07-14",
            coverageUntilKey: "2026-07-16")
        let model = SpendDashboardModel.build(
            inputs: [
                .init(
                    provider: .codex,
                    displayName: "Codex",
                    snapshot: Self.snapshot(
                        entries: [],
                        historyDays: 30,
                        last30DaysTokens: nil,
                        historyCoverageIsEstablished: false),
                    tokenActivityCache: cache),
            ],
            requestedDays: 30,
            now: now,
            calendar: Self.calendar)

        #expect(model.tokenActivity.first { $0.day == beforeCoverage }?.totalTokens == nil)
        #expect(model.tokenActivity.suffix(3).allSatisfy { $0.totalTokens == 0 })
    }

    @Test
    func `weekly and cumulative activity preserve unavailable coverage`() throws {
        let start = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 5)))
        let today = try #require(Self.calendar.date(byAdding: .day, value: 13, to: start))
        var covered = [Bool](repeating: true, count: SpendActivitySeries.weekCount * 7)
        covered[2] = false
        let series = SpendActivitySeries(
            daily: [Int](repeating: 1, count: covered.count),
            isCovered: covered,
            isScanned: [Bool](repeating: true, count: covered.count),
            start: start,
            rangeStart: start,
            today: today,
            calendar: Self.calendar)

        let weekly = series.weeklyActivity()
        #expect(weekly.values.prefix(2) == [7, 7])
        #expect(weekly.isCovered.prefix(2) == [false, true])
        // Every day here was scanned, so the uncovered day is a real gap and every later running
        // total stays a lower bound. See `cumulative activity starts at the first scanned week`
        // for the window-edge case, which does recover.
        #expect(weekly.cumulative().isCovered.prefix(2) == [false, false])
    }

    @Test
    func `cumulative activity starts at the first scanned week`() {
        let weekly = SpendActivityAggregateSeries(
            values: [3, 5, 7],
            isCovered: [false, true, true],
            isScanned: [false, true, true])

        let cumulative = weekly.cumulative()

        #expect(cumulative.isCovered == [false, true, true])
        // Totals are unchanged: an unscanned week contributes whatever its covered days held.
        #expect(cumulative.values == [3, 8, 15])
    }

    @Test
    func `cumulative activity keeps a leading in window gap unavailable`() {
        // Every week was scanned, so the leading unavailable week is missing data rather than a
        // window edge. Later totals are lower bounds and must not read as complete.
        let weekly = SpendActivityAggregateSeries(
            values: [3, 5, 7],
            isCovered: [false, true, true],
            isScanned: [true, true, true])

        let cumulative = weekly.cumulative()

        #expect(cumulative.isCovered == [false, false, false])
        #expect(cumulative.values == [3, 8, 15])
    }

    @Test
    func `series separates an unscanned prefix from an in window gap`() throws {
        let calendar = Self.calendar
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 12)))
        // A 30-day window on a 365-day grid: the first 335 days were never scanned.
        let points = try (0..<SpendActivitySeries.rangeDayCount).map { offset -> SpendDashboardModel
            .TokenActivityPoint in
            let day = try #require(calendar.date(byAdding: .day, value: -offset, to: now))
            guard offset < 30 else {
                return .init(day: day, totalTokens: nil, isScanned: false)
            }
            return .init(day: day, totalTokens: 10)
        }

        let series = SpendActivitySeries.make(from: points, now: now, calendar: calendar)
        let cumulative = series.weeklyActivity().cumulative()
        let visibleWeeks = cumulative.isCovered.indices.filter { week in
            (0..<SpendActivitySeries.dayCount).contains { row in
                series.isVisible(week * SpendActivitySeries.dayCount + row)
            }
        }

        // The unscanned prefix cannot blank the scanned window.
        #expect(visibleWeeks.contains { cumulative.isCovered[$0] })
        #expect(cumulative.values.last == 300)

        // The same shape, but with one scanned day inside the window that cannot be resolved.
        let gapDay = try #require(calendar.date(byAdding: .day, value: -29, to: now))
        let withGap = points.map { point in
            calendar.isDate(point.day, inSameDayAs: gapDay)
                ? SpendDashboardModel.TokenActivityPoint(day: point.day, totalTokens: nil)
                : point
        }
        let gapCumulative = SpendActivitySeries.make(from: withGap, now: now, calendar: calendar)
            .weeklyActivity()
            .cumulative()

        // A real gap at the leading edge keeps every later running total unavailable.
        #expect(!gapCumulative.isCovered.contains(true))
    }

    @Test
    func `trailing unscanned days keep their week and later totals unavailable`() throws {
        let calendar = Self.calendar
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 12)))
        // A stale snapshot: the scan covers now-30 ... now-2, so the two most recent days were
        // never reached. That is missing recent data, not a window edge.
        let points = try (0..<SpendActivitySeries.rangeDayCount).map { offset -> SpendDashboardModel
            .TokenActivityPoint in
            let day = try #require(calendar.date(byAdding: .day, value: -offset, to: now))
            guard (2..<31).contains(offset) else {
                return .init(day: day, totalTokens: nil, isScanned: false)
            }
            return .init(day: day, totalTokens: 10)
        }

        let series = SpendActivitySeries.make(from: points, now: now, calendar: calendar)
        let weekly = series.weeklyActivity()
        let cumulative = weekly.cumulative()

        // The scanned interior still draws.
        #expect(cumulative.isCovered.contains(true))
        // The week holding the trailing unscanned days is a lower bound, so it and everything
        // after it stay unavailable.
        let lastWeek = weekly.isCovered.count - 1
        #expect(weekly.isCovered[lastWeek] == false)
        #expect(cumulative.isCovered[lastWeek] == false)
    }

    @Test
    func `model with a 30 day scan window yields a cumulative view that still draws`() throws {
        let now = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 16)))
        let formatter = DateFormatter()
        formatter.calendar = Self.calendar
        formatter.timeZone = Self.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let entries = try (0..<30).map { offset in
            let day = try #require(Self.calendar.date(byAdding: .day, value: -offset, to: now))
            return Self.entry(day: formatter.string(from: day), cost: nil, tokens: 10)
        }
        let model = SpendDashboardModel.build(
            inputs: [
                .init(
                    provider: .claude,
                    displayName: "Claude",
                    snapshot: Self.snapshot(entries: entries, historyDays: 30, last30DaysTokens: 300)),
            ],
            requestedDays: 30,
            now: now,
            calendar: Self.calendar)
        let outsideDay = try #require(Self.calendar.date(byAdding: .day, value: -30, to: now))
        let insideDay = try #require(Self.calendar.date(byAdding: .day, value: -29, to: now))

        #expect(model.tokenActivity.first { $0.day == outsideDay }?.totalTokens == nil)
        #expect(model.tokenActivity.first { $0.day == outsideDay }?.isScanned == false)
        #expect(model.tokenActivity.first { $0.day == insideDay }?.totalTokens == 10)
        #expect(model.tokenActivity.first { $0.day == insideDay }?.isScanned == true)

        let series = SpendActivitySeries.make(from: model.tokenActivity, now: now, calendar: Self.calendar)
        let cumulative = series.weeklyActivity().cumulative()

        // #2893: keep Cumulative from rendering blank at the default 30-day window.
        #expect(cumulative.isCovered.contains(true))
        #expect(cumulative.values.last == 300)
    }

    @Test
    func `cumulative activity stays unavailable after a gap`() {
        let weekly = SpendActivityAggregateSeries(
            values: [1, 1, 1, 1],
            isCovered: [true, false, true, true])

        let cumulative = weekly.cumulative()

        // A running total across a gap is a lower bound, so every later week stays unavailable.
        #expect(cumulative.isCovered == [true, false, false, false])
        #expect(cumulative.values == [1, 2, 3, 4])
    }

    @Test
    func `annual aggregation output stays fixed with many full year providers`() throws {
        let now = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 16)))
        let formatter = DateFormatter()
        formatter.calendar = Self.calendar
        formatter.timeZone = Self.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let entries = try (0..<SpendDashboardModel.tokenActivityDayCount).map { offset in
            let day = try #require(Self.calendar.date(byAdding: .day, value: -offset, to: now))
            return Self.entry(day: formatter.string(from: day), cost: 0, tokens: 1)
        }
        let snapshot = Self.snapshot(
            entries: entries,
            historyDays: SpendDashboardModel.tokenActivityDayCount,
            last30DaysTokens: SpendDashboardModel.tokenActivityDayCount)
        let inputs = (0..<32).map { index in
            SpendDashboardModel.ProviderInput(
                id: "provider-\(index)",
                provider: .claude,
                displayName: "Provider \(index)",
                snapshot: snapshot)
        }
        let model = SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: 30,
            now: now,
            calendar: Self.calendar)

        #expect(model.tokenActivity.count == SpendDashboardModel.tokenActivityDayCount)
        #expect(model.tokenActivity.allSatisfy { $0.totalTokens == inputs.count })
    }

    @Test
    func `scroll controls indicate available history and clamp bounced offsets`() {
        for offset: CGFloat in [-20, 0, 84.5, 169, 200] {
            let navigation = SpendActivityScrollNavigation(contentWidth: 689, viewportWidth: 520, offset: offset)
            #expect(navigation.isScrollable)
            #expect(navigation.canScrollEarlier == (offset > 0.5))
            #expect(navigation.canScrollLater == (offset < 168.5))
        }
        for width: CGFloat in [0, 689, 760] {
            let navigation = SpendActivityScrollNavigation(
                contentWidth: max(width, 689), viewportWidth: width, offset: 0)
            #expect(!navigation.isScrollable)
            #expect(!navigation.canScrollEarlier)
            #expect(!navigation.canScrollLater)
        }
    }

    @Test
    func `scroll buttons reach both ends with a week of overlap between pages`() {
        for width: CGFloat in [339, 520] {
            let maximumOffset = 689 - width
            for direction in [SpendActivityScrollNavigation.Direction.earlier, .later] {
                var offset = direction == .earlier ? maximumOffset : 0
                var steps = 0
                while direction == .earlier ? offset > 0.5 : offset < maximumOffset - 0.5 {
                    let navigation = SpendActivityScrollNavigation(
                        contentWidth: 689,
                        viewportWidth: width,
                        offset: offset)
                    let column = navigation.targetColumn(toward: direction)
                    let next = min(CGFloat(column) * 13, maximumOffset)
                    #expect(direction == .earlier ? next < offset : next > offset)
                    #expect(abs(next - offset) <= width - 13)
                    offset = next
                    steps += 1
                    #expect(steps <= 3)
                    if steps > 3 { break }
                }
                #expect(offset == (direction == .earlier ? 0 : maximumOffset))
            }
        }
    }

    @Test
    func `annual grid keeps readable square cells and grows beyond narrow viewports`() {
        for viewportWidth: CGFloat in [339, 520, 689, 760] {
            let frame = SpendActivityGridGeometry.gridFrame(containerWidth: viewportWidth)
            let pitch = frame.width / CGFloat(SpendActivitySeries.weekCount)
            #expect(frame.minX == 0)
            #expect(frame.width >= viewportWidth)
            #expect(pitch - SpendActivityGridGeometry.cellSpacing >= 10)
            #expect(frame.height == pitch * 7)
            #expect(frame.width == max(viewportWidth, 689))
        }
    }

    @Test
    func `tooltips remain inside the visible portion of a scrolled annual grid`() {
        for offset: CGFloat in [0, 150, 350] {
            let visible = CGRect(x: offset, y: 0, width: 339, height: 91)
            for anchor: CGFloat in [visible.minX + 6.5, visible.midX, visible.maxX - 6.5] {
                let center = SpendActivityGridGeometry.tooltipCenterX(
                    anchorX: anchor, tooltipWidth: 148, gridWidth: 689, visibleRect: visible)
                #expect(center - 74 >= visible.minX + SpendActivityGridGeometry.tooltipInset)
                #expect(center + 74 <= visible.maxX - SpendActivityGridGeometry.tooltipInset)
            }
        }
    }

    @Test
    func `grid keyboard navigation follows rows and weeks without wrapping`() {
        #expect(SpendActivityGridNavigation.candidate(from: 10, move: .left, rows: 7) == 3)
        #expect(SpendActivityGridNavigation.candidate(from: 10, move: .right, rows: 7) == 17)
        #expect(SpendActivityGridNavigation.candidate(from: 10, move: .up, rows: 7) == 9)
        #expect(SpendActivityGridNavigation.candidate(from: 10, move: .down, rows: 7) == 11)
        #expect(SpendActivityGridNavigation.candidate(from: 7, move: .up, rows: 7) == nil)
        #expect(SpendActivityGridNavigation.candidate(from: 13, move: .down, rows: 7) == nil)
    }

    @Test
    func `tooltip stays beside the hovered cell and clamps only at the edge`() {
        let gridWidth: CGFloat = 1000
        let width = SpendActivityGridGeometry.tooltipWidth
        let centered = SpendActivityGridGeometry.tooltipCenterX(
            anchorX: 500,
            tooltipWidth: width,
            gridWidth: gridWidth)
        let trailing = SpendActivityGridGeometry.tooltipCenterX(
            anchorX: 995,
            tooltipWidth: width,
            gridWidth: gridWidth)

        #expect(centered == 500)
        #expect(trailing > 900)
        #expect(trailing <= gridWidth - width / 2)
    }

    @Test
    func `tooltip prefers sitting above the hovered cell when there is room`() {
        let originY = SpendActivityGridGeometry.tooltipOriginY(
            anchorY: 120,
            tooltipHeight: 50,
            gridHeight: 130)
        #expect(originY == 120 - 50 - SpendActivityGridGeometry.tooltipGap)
    }

    @Test
    func `tooltip never renders outside the grid when there is no room above`() {
        let gridHeight: CGFloat = 130
        let tooltipHeight: CGFloat = 50
        for anchorY: CGFloat in [0, 10, 30] {
            let originY = SpendActivityGridGeometry.tooltipOriginY(
                anchorY: anchorY,
                tooltipHeight: tooltipHeight,
                gridHeight: gridHeight)
            #expect(originY >= 0)
            #expect(originY + tooltipHeight <= gridHeight)
        }
    }

    @Test
    func `tooltip compacts instead of overflowing a grid shorter than its full height`() {
        // Roughly matches the grid produced at the supported 800pt minimum window width
        // with the sidebar expanded to 380pt, where the heatmap has very little height to work with.
        let gridHeight: CGFloat = 38
        let height = SpendActivityGridGeometry.effectiveTooltipHeight(gridHeight: gridHeight)
        #expect(height <= gridHeight)

        for anchorY: CGFloat in [0, 10, 19, 30, gridHeight] {
            let originY = SpendActivityGridGeometry.tooltipOriginY(
                anchorY: anchorY,
                tooltipHeight: height,
                gridHeight: gridHeight)
            #expect(originY >= 0)
            #expect(originY + height <= gridHeight)
        }
    }

    @Test
    func `date formatting follows the selected resource locale`() throws {
        let date = try #require(Self.calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 1, hour: 12)))
        let english = Locale(identifier: "en_US")
        let chinese = Locale(identifier: "zh_Hans")

        #expect(SpendActivityDateFormatting.mediumDateString(date, locale: english).contains("Aug"))
        #expect(!SpendActivityDateFormatting.mediumDateString(date, locale: english).contains("年"))
        #expect(SpendActivityDateFormatting.mediumDateString(date, locale: chinese).contains("年"))
    }

    @Test
    func `accessibility descriptions publish localized dates and availability values`() throws {
        let date = try #require(Self.calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 1, hour: 12)))
        let locale = Locale(identifier: "en_US")

        #expect(SpendActivityAccessibility.description(
            date: date,
            value: "1.2K",
            locale: locale) == "Aug 1, 2026: 1.2K")
        #expect(SpendActivityAccessibility.description(
            date: date,
            value: "Unavailable",
            locale: locale) == "Aug 1, 2026: Unavailable")
    }

    @Test
    func `uncovered heatmap days do not produce a drill-down selection`() throws {
        let calendar = Self.calendar
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 2)))
        let series = SpendActivitySeries(
            daily: [10, 0],
            isCovered: [true, false],
            isScanned: [true, true],
            start: start,
            rangeStart: start,
            today: start,
            calendar: calendar)
        #expect(SpendActivityDaySelection.day(from: series, at: 0, selectedDay: nil) == start)
        #expect(SpendActivityDaySelection.day(from: series, at: 1, selectedDay: nil) == nil)
        #expect(SpendActivityDaySelection.day(from: series, at: 0, selectedDay: start) == nil)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func snapshot(
        entries: [CostUsageDailyReport.Entry],
        historyDays: Int = 365,
        last30DaysTokens: Int?,
        historyCoverageIsEstablished: Bool = true) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: nil,
            currencyCode: "USD",
            historyDays: historyDays,
            historyCoverageIsEstablished: historyCoverageIsEstablished,
            daily: entries,
            updatedAt: Date(timeIntervalSince1970: 1_784_179_200))
    }

    private static func entry(day: String, cost: Double?, tokens: Int?) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: [])
    }
}

extension SpendActivitySeries {
    fileprivate init(
        daily: [Int],
        isCovered: [Bool],
        isScanned: [Bool],
        start: Date,
        rangeStart: Date,
        today: Date,
        calendar: Calendar)
    {
        let dates = daily.indices.map { index in
            calendar.date(byAdding: .day, value: index, to: start).map { calendar.startOfDay(for: $0) }
        }
        let visible = dates.indices.filter { index in
            dates[index].map { rangeStart...today ~= $0 } ?? false
        }
        self.init(
            daily: daily,
            isCovered: isCovered,
            isScanned: isScanned,
            start: start,
            rangeStart: rangeStart,
            today: today,
            calendar: calendar,
            dates: dates,
            visibleIndices: visible,
            coveredDayCount: visible.count(where: { isCovered[$0] }))
    }
}
