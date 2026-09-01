import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageQuotaWeekLinuxTests {
    @Test
    func `rolling weeks match last 7 calendar days when reset is unknown`() {
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [
                Self.entry(day: "2026-07-01", cost: 1, tokens: 100),
                Self.entry(day: "2026-07-08", cost: 3, tokens: 300),
                Self.entry(day: "2026-07-09", cost: 2, tokens: 200),
                Self.entry(day: "2026-07-15", cost: 5, tokens: 500),
            ],
            updatedAt: Self.utcDate(year: 2026, month: 7, day: 15, hour: 12))

        let weeks = snapshot.quotaWeekSummaries(resetAt: nil, calendar: Self.utcCalendar)
        let current = weeks.first { $0.offset == 0 }
        let last = weeks.first { $0.offset == 1 }

        #expect(current?.totalCostUSD == 7)
        #expect(current?.totalTokens == 700)
        #expect(current?.entryCount == 2)
        #expect(last?.totalCostUSD == 3)
        #expect(last?.totalTokens == 300)
        #expect(weeks.first { $0.offset == 2 }?.totalCostUSD == 1)
    }

    @Test
    func `sparse observed resets fill nominal weekly boundaries inside the gap`() {
        let live = Self.utcDate(year: 2026, month: 9, day: 30, hour: 15)
        let observed = Self.utcDate(year: 2026, month: 8, day: 30, hour: 15)
        let now = Self.utcDate(year: 2026, month: 9, day: 15, hour: 12)
        let boundaries = CostUsageTokenSnapshot.quotaWeekBoundaries(
            liveNextReset: live,
            observedNextResets: [observed],
            weekCount: 4,
            now: now,
            calendar: Self.utcCalendar)

        #expect(boundaries.contains(observed))
        #expect(boundaries.contains(Self.utcDate(year: 2026, month: 9, day: 6, hour: 15)))
        #expect(boundaries.contains(Self.utcDate(year: 2026, month: 9, day: 13, hour: 15)))
        #expect(boundaries.contains(Self.utcDate(year: 2026, month: 9, day: 20, hour: 15)))
        #expect(boundaries.contains(live))
        #expect(zip(boundaries, boundaries.dropFirst()).contains { earlier, later in
            earlier == observed && later == live
        } == false)
    }

    @Test
    func `fallback week boundaries stay on local midnight after DST fall-back`() {
        let calendar = Self.losAngelesCalendar
        let now = Self.losAngelesDate(year: 2026, month: 11, day: 3, hour: 12)
        let currentEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let currentStart = calendar.date(byAdding: .day, value: -7, to: currentEnd)!
        let durationStart = currentEnd.addingTimeInterval(
            -TimeInterval(CostUsageTokenSnapshot.quotaWeekMinutes * 60))
        #expect(calendar.component(.hour, from: currentStart) == 0)
        #expect(calendar.component(.hour, from: durationStart) != 0)

        let boundaries = CostUsageTokenSnapshot.quotaWeekBoundaries(
            liveNextReset: nil,
            observedNextResets: [],
            weekCount: 2,
            now: now,
            calendar: calendar)
        #expect(boundaries.last == currentEnd)
        #expect(boundaries.contains(currentStart))
        #expect(calendar.component(.hour, from: boundaries[boundaries.count - 2]) == 0)

        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [Self.entry(day: "2026-10-28", cost: 4, tokens: 400)],
            updatedAt: now)
        let current = snapshot.quotaWeekSummaries(resetAt: nil, now: now, calendar: calendar)
            .first { $0.isCurrent }
        #expect(current?.start == currentStart)
        #expect(current?.totalCostUSD == 4)
        #expect(current?.totalTokens == 400)
    }

    @Test
    func `invalid day contributions fail closed instead of summing partial window cost`() {
        let now = Self.utcDate(year: 2026, month: 7, day: 15, hour: 12)
        let resetAt = Self.utcDate(year: 2026, month: 7, day: 18, hour: 15)
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [
                Self.entry(day: "2026-07-13", cost: 10, tokens: 1000),
                Self.entry(day: "2026-07-14", cost: nil, tokens: 200),
            ],
            updatedAt: now)

        let current = snapshot.quotaWeekSummaries(
            resetAt: resetAt,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            calendar: Self.utcCalendar).first { $0.isCurrent }

        #expect(current?.totalCostUSD == nil)
        #expect(current?.totalTokens == 1200)
    }

    @Test
    func `quota windows that start before scanned history are omitted`() {
        let snapshot = Self.snapshot(
            historyDays: 7,
            daily: [
                Self.entry(day: "2026-07-10", cost: 2, tokens: 20),
                Self.entry(day: "2026-07-13", cost: 5, tokens: 50),
            ],
            updatedAt: Self.utcDate(year: 2026, month: 7, day: 15, hour: 12))

        let weeks = snapshot.quotaWeekSummaries(
            resetAt: Self.utcDate(year: 2026, month: 7, day: 18, hour: 15),
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            calendar: Self.utcCalendar)
        #expect(weeks.map(\.offset) == [0])
        #expect(weeks.first?.totalCostUSD == 5)
        #expect(weeks.first?.totalTokens == 50)
    }

    @Test
    func `quota weeks align to the live weekly reset instead of calendar last 7 days`() {
        let now = Self.utcDate(year: 2026, month: 7, day: 15, hour: 12)
        let resetAt = Self.utcDate(year: 2026, month: 7, day: 18, hour: 15)
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [
                Self.entry(day: "2026-07-08", cost: 4, tokens: 400),
                Self.entry(day: "2026-07-13", cost: 10, tokens: 1000),
                Self.entry(day: "2026-07-20", cost: 99, tokens: 9900),
            ],
            updatedAt: now)

        let weeks = snapshot.quotaWeekSummaries(
            resetAt: resetAt,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            calendar: Self.utcCalendar)
        let current = weeks.first { $0.isCurrent }
        let previous = weeks.first { $0.offset == 1 }

        #expect(current?.totalCostUSD == 10)
        #expect(current?.totalTokens == 1000)
        #expect(previous?.totalCostUSD == 4)
        #expect(previous?.totalTokens == 400)
        #expect(weeks.contains { $0.totalCostUSD == 99 } == false)
    }

    @Test
    func `stale reset advances by whole weeks until it covers now`() {
        let now = Self.utcDate(year: 2026, month: 7, day: 15, hour: 12)
        let staleReset = Self.utcDate(year: 2026, month: 7, day: 4, hour: 15)
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [
                Self.entry(day: "2026-07-08", cost: 3, tokens: 300),
                Self.entry(day: "2026-07-13", cost: 8, tokens: 800),
            ],
            updatedAt: now)

        let weeks = snapshot.quotaWeekSummaries(resetAt: staleReset, calendar: Self.utcCalendar)
        #expect(weeks.first?.isCurrent == true)
        #expect((weeks.first?.end ?? .distantPast) > now)
        #expect(weeks.first?.totalCostUSD == 8)
        #expect(weeks.first { $0.offset == 1 }?.totalCostUSD == 3)
    }

    @Test
    func `live reset wins over a nearby earlier observed reset`() {
        let liveReset = Self.utcDate(year: 2026, month: 7, day: 18, hour: 15)
        let observedReset = liveReset.addingTimeInterval(-60)
        let now = observedReset.addingTimeInterval(30)

        let boundaries = CostUsageTokenSnapshot.quotaWeekBoundaries(
            liveNextReset: liveReset,
            observedNextResets: [observedReset],
            weekCount: 2,
            now: now,
            calendar: Self.utcCalendar)

        #expect(boundaries.last == liveReset)
        #expect((boundaries.last ?? .distantPast) > now)
    }

    @Test
    func `historical weeks outside the scanned history are omitted`() {
        let snapshot = Self.snapshot(
            historyDays: 7,
            daily: [Self.entry(day: "2026-07-15", cost: 5, tokens: 50)],
            updatedAt: Self.utcDate(year: 2026, month: 7, day: 15, hour: 12))

        let weeks = snapshot.quotaWeekSummaries(resetAt: nil, calendar: Self.utcCalendar)
        #expect(weeks.map(\.offset) == [0])
        #expect(weeks.first?.totalCostUSD == 5)
    }

    @Test
    func `daily fallback omits a split calendar day and keeps contained neighbors`() {
        let now = Self.utcDate(year: 2026, month: 7, day: 12, hour: 12)
        let resetAt = Self.utcDate(year: 2026, month: 7, day: 18, hour: 15)
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [
                Self.entry(day: "2026-07-11", cost: 6, tokens: 600),
                Self.entry(day: "2026-07-12", cost: 2, tokens: 200),
            ],
            updatedAt: now)

        let weeks = snapshot.quotaWeekSummaries(
            resetAt: resetAt,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            calendar: Self.utcCalendar)
        let current = weeks.first { $0.isCurrent }
        let previous = weeks.first { $0.offset == 1 }

        #expect(current?.totalCostUSD == 2)
        #expect(current?.totalTokens == 200)
        #expect(previous?.totalCostUSD == nil)
        #expect(previous?.totalTokens == nil)
    }

    @Test
    func `hourly buckets split the reset day at the reset instant`() {
        let now = Self.utcDate(year: 2026, month: 7, day: 12, hour: 12)
        let resetAt = Self.utcDate(year: 2026, month: 7, day: 11, hour: 15)
        let hourBefore = Self.utcDate(year: 2026, month: 7, day: 11, hour: 14)
        let hourAtReset = Self.utcDate(year: 2026, month: 7, day: 11, hour: 15)
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [
                Self.entry(day: "2026-07-11", cost: 6, tokens: 600),
            ],
            hourly: [
                CostUsageHourlyEntry(hour: hourBefore, totalTokens: 200, costUSD: 2),
                CostUsageHourlyEntry(hour: hourAtReset, totalTokens: 400, costUSD: 4),
            ],
            updatedAt: now)

        let weeks = snapshot.quotaWeekSummaries(
            resetAt: resetAt,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            calendar: Self.utcCalendar)
        let current = weeks.first { $0.isCurrent }
        let previous = weeks.first { $0.offset == 1 }

        #expect(current?.totalCostUSD == 4)
        #expect(current?.totalTokens == 400)
        #expect(previous?.totalCostUSD == 2)
        #expect(previous?.totalTokens == 200)
        #expect((current?.totalCostUSD ?? 0) + (previous?.totalCostUSD ?? 0) == 6)
        #expect(current?.entryCount == 1)
        #expect(previous?.entryCount == 1)
    }

    @Test
    func `hourly membership is exclusive across adjacent weeks`() {
        let now = Self.utcDate(year: 2026, month: 7, day: 15, hour: 12)
        let resetAt = Self.utcDate(year: 2026, month: 7, day: 18, hour: 15)
        var hours: [CostUsageHourlyEntry] = []
        for day in 8...15 {
            for hour in [0, 14, 15, 23] {
                hours.append(CostUsageHourlyEntry(
                    hour: Self.utcDate(year: 2026, month: 7, day: day, hour: hour),
                    totalTokens: 10,
                    costUSD: 1))
            }
        }
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [],
            hourly: hours,
            updatedAt: now)

        let weeks = snapshot.quotaWeekSummaries(
            resetAt: resetAt,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            calendar: Self.utcCalendar)
        let counted = weeks.reduce(0) { $0 + $1.entryCount }
        let cost = weeks.compactMap(\.totalCostUSD).reduce(0, +)
        #expect(counted == hours.count)
        #expect(cost == Double(hours.count))
    }

    @Test
    func `partial hourly coverage preserves complete daily totals across quota windows`() {
        let now = Self.utcDate(year: 2026, month: 7, day: 15, hour: 12)
        let resetAt = Self.utcDate(year: 2026, month: 7, day: 18, hour: 15)
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [
                Self.entry(day: "2026-07-08", cost: 4, tokens: 400),
                Self.entry(day: "2026-07-13", cost: 10, tokens: 1000),
            ],
            hourly: [
                // Only part of the current day's known daily total has hour-level evidence.
                CostUsageHourlyEntry(
                    hour: Self.utcDate(year: 2026, month: 7, day: 13, hour: 12),
                    totalTokens: 600,
                    costUSD: 6),
            ],
            updatedAt: now)

        let weeks = snapshot.quotaWeekSummaries(
            resetAt: resetAt,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            calendar: Self.utcCalendar)
        let current = weeks.first { $0.isCurrent }
        let previous = weeks.first { $0.offset == 1 }

        #expect(current?.totalCostUSD == 10)
        #expect(current?.totalTokens == 1000)
        #expect(previous?.totalCostUSD == 4)
        #expect(previous?.totalTokens == 400)
        #expect(weeks.compactMap(\.totalCostUSD).reduce(0, +) == 14)
        #expect(weeks.compactMap(\.totalTokens).reduce(0, +) == 1400)
    }

    @Test
    func `unknown hourly cost keeps the quota window total unknown`() {
        let now = Self.utcDate(year: 2026, month: 7, day: 15, hour: 12)
        let resetAt = Self.utcDate(year: 2026, month: 7, day: 18, hour: 15)
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [Self.entry(day: "2026-07-13", cost: nil, tokens: 300)],
            hourly: [
                CostUsageHourlyEntry(
                    hour: Self.utcDate(year: 2026, month: 7, day: 13, hour: 10),
                    totalTokens: 100,
                    costUSD: 2),
                CostUsageHourlyEntry(
                    hour: Self.utcDate(year: 2026, month: 7, day: 13, hour: 11),
                    totalTokens: 200,
                    costUSD: nil),
            ],
            updatedAt: now)

        let current = snapshot.quotaWeekSummaries(
            resetAt: resetAt,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            calendar: Self.utcCalendar).first { $0.isCurrent }

        #expect(current?.totalCostUSD == nil)
        #expect(current?.totalTokens == 300)
    }

    @Test
    func `session window minutes are ignored for weekly alignment`() {
        let session = RateWindow(
            usedPercent: 10,
            windowMinutes: 5 * 60,
            resetsAt: Self.utcDate(year: 2026, month: 7, day: 15, hour: 18),
            resetDescription: nil)
        #expect(CostUsageTokenSnapshot.quotaWeekReset(from: session) == nil)
        #expect(CostUsageTokenSnapshot.normalizedQuotaWeekMinutes(session.windowMinutes)
            == CostUsageTokenSnapshot.quotaWeekMinutes)
    }

    @Test
    func `merged report keeps real hourly data without synthesizing midnight residuals`() {
        let hour = Self.utcDate(year: 2026, month: 7, day: 11, hour: 15)
        let native = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-11",
                    inputTokens: 100,
                    outputTokens: 20,
                    totalTokens: 120,
                    costUSD: 1.2,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: nil),
            ],
            summary: nil,
            hourly: [CostUsageHourlyEntry(hour: hour, totalTokens: 120, costUSD: 1.2)])
        let pi = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-11",
                    inputTokens: 10,
                    outputTokens: 5,
                    totalTokens: 15,
                    costUSD: 0.3,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: nil),
            ],
            summary: nil)

        let merged = CostUsageDailyReport.merged([native, pi], calendar: Self.utcCalendar)
        #expect(merged.hourly.count == 1)
        let resetHour = merged.hourly.first { $0.hour == hour }
        let midnight = merged.hourly.first { $0.hour == Self.utcDate(year: 2026, month: 7, day: 11, hour: 0) }
        #expect(resetHour?.costUSD == 1.2)
        #expect(resetHour?.totalTokens == 120)
        #expect(midnight == nil)

        let now = Self.utcDate(year: 2026, month: 7, day: 11, hour: 20)
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: merged,
            now: now,
            historyDays: 30,
            calendar: Self.utcCalendar)
        #expect(snapshot.hourly == native.hourly)
        let current = snapshot.quotaWeekSummaries(
            resetAt: Self.utcDate(year: 2026, month: 7, day: 12, hour: 0),
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            now: now,
            calendar: Self.utcCalendar).first { $0.isCurrent }

        #expect(current?.totalCostUSD == 1.5)
        #expect(current?.totalTokens == 135)
    }

    @Test
    func `merged daily normalizes day-only and ISO dates to one local day`() {
        let calendar = Self.losAngelesCalendar
        let merged = CostUsageDailyReport.merged(
            [
                CostUsageDailyReport(
                    data: [Self.entry(day: "2026-07-11", cost: 1, tokens: 100)],
                    summary: nil),
                CostUsageDailyReport(
                    data: [
                        // Provider day labels retain their YYYY-MM-DD prefix when timestamp-shaped.
                        Self.entry(day: "2026-07-11T23:30:00Z", cost: 2, tokens: 200),
                    ],
                    summary: nil),
            ],
            calendar: calendar)

        #expect(merged.data.count == 1)
        #expect(merged.data.first?.date == "2026-07-11")
        #expect(merged.data.first?.totalTokens == 300)
        #expect(merged.data.first?.costUSD == 3)
        #expect(merged.summary?.totalTokens == 300)
        #expect(merged.summary?.totalCostUSD == 3)

        let now = Self.isoDate("2026-07-12T06:45:00Z")
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: merged,
            now: now,
            historyDays: 30,
            calendar: calendar)
        let current = snapshot.quotaWeekSummaries(
            resetAt: Self.isoDate("2026-07-12T07:00:00Z"),
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            now: now,
            calendar: calendar).first { $0.isCurrent }

        #expect(current?.totalTokens == 300)
        #expect(current?.totalCostUSD == 3)
    }

    @Test
    func `fall-back repeated hours keep exact and residual evidence separate`() {
        let calendar = Self.losAngelesCalendar
        let firstHour = Self.isoDate("2026-11-01T08:00:00Z")
        let secondHour = Self.isoDate("2026-11-01T09:00:00Z")
        let firstEvent = Self.isoDate("2026-11-01T08:15:00Z")
        let secondEvent = Self.isoDate("2026-11-01T09:15:00Z")
        #expect(calendar.component(.hour, from: firstEvent) == 1)
        #expect(calendar.component(.hour, from: secondEvent) == 1)
        #expect(firstHour != secondHour)

        let newer = CostUsageDailyReport(
            data: [],
            summary: nil,
            hourly: [
                CostUsageHourlyEntry(hour: firstHour, totalTokens: 100, costUSD: 1),
                CostUsageHourlyEntry(hour: secondHour, totalTokens: 200, costUSD: 2),
            ],
            quotaSlices: [
                CostUsageTimedEntry(timestamp: firstEvent, totalTokens: 100, costUSD: 1),
                CostUsageTimedEntry(timestamp: secondEvent, totalTokens: 200, costUSD: 2),
            ])
        let legacy = CostUsageDailyReport(
            data: [],
            summary: nil,
            hourly: [
                CostUsageHourlyEntry(hour: firstHour, totalTokens: 300, costUSD: 3),
                CostUsageHourlyEntry(hour: secondHour, totalTokens: 500, costUSD: 5),
            ])

        let merged = CostUsageDailyReport.merged([newer, legacy], calendar: calendar)
        #expect(merged.hourly.count == 2)
        let firstBucket = merged.hourly.first { $0.hour == firstHour }
        let secondBucket = merged.hourly.first { $0.hour == secondHour }
        #expect(firstBucket?.totalTokens == 400)
        #expect(firstBucket?.costUSD == 4)
        #expect(secondBucket?.totalTokens == 700)
        #expect(secondBucket?.costUSD == 7)
        #expect(merged.quotaSlices == newer.quotaSlices)

        let now = Self.isoDate("2026-11-01T10:30:00Z")
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: merged,
            now: now,
            historyDays: 30,
            calendar: calendar)
        let weeks = snapshot.quotaWeekSummaries(
            resetAt: secondHour,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            now: now,
            calendar: calendar)
        let current = weeks.first { $0.isCurrent }
        let previous = weeks.first { $0.offset == 1 }

        #expect(current?.totalTokens == 700)
        #expect(current?.totalCostUSD == 7)
        #expect(previous?.totalTokens == 400)
        #expect(previous?.totalCostUSD == 4)
    }

    @Test
    func `new exact and hourly data combines with legacy hourly without double counting`() {
        let hour = Self.utcDate(year: 2026, month: 7, day: 11, hour: 10)
        let exactTimestamp = Self.utcDate(year: 2026, month: 7, day: 11, hour: 10, minute: 15)
        let newer = CostUsageDailyReport(
            data: [],
            summary: nil,
            hourly: [
                CostUsageHourlyEntry(hour: hour, totalTokens: 100, costUSD: 1),
            ],
            quotaSlices: [
                CostUsageTimedEntry(timestamp: exactTimestamp, totalTokens: 100, costUSD: 1),
            ])
        let legacyHourly = CostUsageDailyReport(
            data: [],
            summary: nil,
            hourly: [
                CostUsageHourlyEntry(hour: hour, totalTokens: 300, costUSD: 3),
            ])

        let merged = CostUsageDailyReport.merged(
            [newer, legacyHourly],
            calendar: Self.utcCalendar)
        #expect(merged.data.isEmpty)
        #expect(merged.quotaSlices == newer.quotaSlices)
        #expect(merged.hourly == [
            CostUsageHourlyEntry(hour: hour, totalTokens: 400, costUSD: 4),
        ])

        let now = Self.utcDate(year: 2026, month: 7, day: 11, hour: 12)
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: merged,
            now: now,
            historyDays: 30,
            calendar: Self.utcCalendar)
        let previous = snapshot.quotaWeekSummaries(
            resetAt: Self.utcDate(year: 2026, month: 7, day: 11, hour: 11),
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            now: now,
            calendar: Self.utcCalendar).first { $0.offset == 1 }

        // Projection keeps the exact event plus only the hourly-minus-exact legacy residual.
        #expect(previous?.totalTokens == 400)
        #expect(previous?.totalCostUSD == 4)
    }

    @Test
    func `exact-only report combines with legacy hourly without daily rows`() {
        let hour = Self.utcDate(year: 2026, month: 7, day: 11, hour: 10)
        let exactTimestamp = Self.utcDate(year: 2026, month: 7, day: 11, hour: 10, minute: 15)
        let merged = CostUsageDailyReport.merged(
            [
                CostUsageDailyReport(
                    data: [],
                    summary: nil,
                    quotaSlices: [
                        CostUsageTimedEntry(timestamp: exactTimestamp, totalTokens: 100, costUSD: 1),
                    ]),
                CostUsageDailyReport(
                    data: [],
                    summary: nil,
                    hourly: [
                        CostUsageHourlyEntry(hour: hour, totalTokens: 300, costUSD: 3),
                    ]),
            ],
            calendar: Self.utcCalendar)

        #expect(merged.data.isEmpty)
        #expect(merged.hourly == [
            CostUsageHourlyEntry(hour: hour, totalTokens: 400, costUSD: 4),
        ])
        let now = Self.utcDate(year: 2026, month: 7, day: 11, hour: 12)
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: merged,
            now: now,
            historyDays: 30,
            calendar: Self.utcCalendar)
        let previous = snapshot.quotaWeekSummaries(
            resetAt: Self.utcDate(year: 2026, month: 7, day: 11, hour: 11),
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            now: now,
            calendar: Self.utcCalendar).first { $0.offset == 1 }

        #expect(previous?.totalTokens == 400)
        #expect(previous?.totalCostUSD == 4)
    }

    @Test
    func `reset inside a mixed exact and legacy residual hour keeps the exact event`() {
        let hour = Self.utcDate(year: 2026, month: 7, day: 11, hour: 10)
        let exactTimestamp = Self.utcDate(year: 2026, month: 7, day: 11, hour: 10, minute: 15)
        let merged = CostUsageDailyReport.merged(
            [
                CostUsageDailyReport(
                    data: [],
                    summary: nil,
                    hourly: [
                        CostUsageHourlyEntry(hour: hour, totalTokens: 100, costUSD: 1),
                    ],
                    quotaSlices: [
                        CostUsageTimedEntry(timestamp: exactTimestamp, totalTokens: 100, costUSD: 1),
                    ]),
                CostUsageDailyReport(
                    data: [],
                    summary: nil,
                    hourly: [
                        CostUsageHourlyEntry(hour: hour, totalTokens: 300, costUSD: 3),
                    ]),
            ],
            calendar: Self.utcCalendar)

        let now = Self.utcDate(year: 2026, month: 7, day: 11, hour: 12)
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: merged,
            now: now,
            historyDays: 30,
            calendar: Self.utcCalendar)
        let weeks = snapshot.quotaWeekSummaries(
            resetAt: Self.utcDate(year: 2026, month: 7, day: 11, hour: 10, minute: 30),
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            now: now,
            calendar: Self.utcCalendar)
        let current = weeks.first { $0.offset == 0 }
        let previous = weeks.first { $0.offset == 1 }

        #expect(previous?.totalTokens == 100)
        #expect(previous?.totalCostUSD == 1)
        #expect(current?.totalTokens == nil)
        #expect(current?.totalCostUSD == nil)
    }

    @Test
    func `merged daily cost stays unknown when active source omits cost and coverage counts`() {
        let merged = CostUsageDailyReport.merged([
            CostUsageDailyReport(
                data: [Self.entry(day: "2026-07-11", cost: 1, tokens: 100)],
                summary: nil),
            CostUsageDailyReport(
                data: [Self.entry(day: "2026-07-11", cost: nil, tokens: 200)],
                summary: nil),
        ])

        #expect(merged.data.count == 1)
        #expect(merged.data.first?.totalTokens == 300)
        #expect(merged.data.first?.costUSD == nil)
        #expect(merged.summary?.totalTokens == 300)
        #expect(merged.summary?.totalCostUSD == nil)

        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: merged,
            now: Self.utcDate(year: 2026, month: 7, day: 11, hour: 12),
            historyDays: 30,
            calendar: Self.utcCalendar)
        #expect(snapshot.last30DaysTokens == 300)
        #expect(snapshot.last30DaysCostUSD == nil)
    }

    @Test
    func `merged daily tokens stay unknown when active source omits tokens and coverage counts`() {
        let merged = CostUsageDailyReport.merged([
            CostUsageDailyReport(
                data: [Self.entry(day: "2026-07-11", cost: 1, tokens: 100)],
                summary: nil),
            CostUsageDailyReport(
                data: [Self.entry(day: "2026-07-11", cost: 2, tokens: nil)],
                summary: nil),
        ])

        #expect(merged.data.count == 1)
        #expect(merged.data.first?.totalTokens == nil)
        #expect(merged.data.first?.costUSD == 3)
        #expect(merged.summary?.totalTokens == nil)
        #expect(merged.summary?.totalCostUSD == 3)

        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: merged,
            now: Self.utcDate(year: 2026, month: 7, day: 11, hour: 12),
            historyDays: 30,
            calendar: Self.utcCalendar)
        #expect(snapshot.last30DaysTokens == nil)
        #expect(snapshot.last30DaysCostUSD == 3)
    }

    @Test
    func `observed official and banked resets on the same day become separate windows`() {
        let now = Self.utcDate(year: 2026, month: 7, day: 17, hour: 12)
        let official = Self.utcDate(year: 2026, month: 7, day: 16, hour: 15)
        let banked = Self.utcDate(year: 2026, month: 7, day: 16, hour: 18)
        let liveNext = Self.utcDate(year: 2026, month: 7, day: 23, hour: 18)
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [Self.entry(day: "2026-07-16", cost: 6, tokens: 600)],
            hourly: [
                CostUsageHourlyEntry(
                    hour: Self.utcDate(year: 2026, month: 7, day: 16, hour: 14),
                    totalTokens: 100,
                    costUSD: 1),
                CostUsageHourlyEntry(
                    hour: Self.utcDate(year: 2026, month: 7, day: 16, hour: 16),
                    totalTokens: 200,
                    costUSD: 2),
                CostUsageHourlyEntry(
                    hour: Self.utcDate(year: 2026, month: 7, day: 16, hour: 19),
                    totalTokens: 300,
                    costUSD: 3),
            ],
            updatedAt: now)

        let weeks = snapshot.quotaWeekSummaries(
            resetAt: liveNext,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            observedNextResets: [official],
            now: now,
            calendar: Self.utcCalendar)
        let current = weeks.first { $0.isCurrent }
        let afterOfficial = weeks.first { $0.offset == 1 }
        let beforeOfficial = weeks.first { $0.offset == 2 }

        #expect(current?.start == banked)
        #expect(current?.totalCostUSD == 3)
        #expect(current?.isNominalWeek == true)
        #expect(afterOfficial?.start == official)
        #expect(afterOfficial?.end == banked)
        #expect(afterOfficial?.totalCostUSD == 2)
        #expect(afterOfficial?.isNominalWeek == false)
        #expect(beforeOfficial?.end == official)
        #expect(beforeOfficial?.totalCostUSD == 1)
        #expect(beforeOfficial?.isNominalWeek == true)
    }

    @Test
    func `future observed reset contributes history start without splitting live window`() {
        let now = Self.utcDate(year: 2026, month: 7, day: 18, hour: 12)
        let observedNext = Self.utcDate(year: 2026, month: 7, day: 23, hour: 15)
        let liveNext = Self.utcDate(year: 2026, month: 7, day: 24, hour: 15)
        let previousEvent = Self.utcDate(year: 2026, month: 7, day: 16, hour: 16)
        let currentEvent = Self.utcDate(year: 2026, month: 7, day: 17, hour: 16)
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [],
            hourly: [
                CostUsageHourlyEntry(hour: previousEvent, totalTokens: 200, costUSD: 2),
                CostUsageHourlyEntry(hour: currentEvent, totalTokens: 300, costUSD: 3),
            ],
            updatedAt: now)

        let weeks = snapshot.quotaWeekSummaries(
            resetAt: liveNext,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            observedNextResets: [observedNext],
            now: now,
            calendar: Self.utcCalendar)
        let current = weeks.first { $0.isCurrent }
        let previous = weeks.first { $0.offset == 1 }

        #expect(current?.start == Self.utcDate(year: 2026, month: 7, day: 17, hour: 15))
        #expect(current?.end == liveNext)
        #expect(current?.totalTokens == 300)
        #expect(previous?.start == Self.utcDate(year: 2026, month: 7, day: 16, hour: 15))
        #expect(previous?.end == current?.start)
        #expect(previous?.totalTokens == 200)
    }

    private static func snapshot(
        historyDays: Int,
        daily: [CostUsageDailyReport.Entry],
        hourly: [CostUsageHourlyEntry] = [],
        updatedAt: Date) -> CostUsageTokenSnapshot
    {
        let tokens = daily.compactMap(\.totalTokens)
        let costs = daily.compactMap(\.costUSD)
        return CostUsageTokenSnapshot(
            sessionTokens: daily.last?.totalTokens,
            sessionCostUSD: daily.last?.costUSD,
            last30DaysTokens: tokens.isEmpty ? nil : tokens.reduce(0, +),
            last30DaysCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
            historyDays: historyDays,
            daily: daily,
            hourly: hourly,
            updatedAt: updatedAt)
    }

    private static func entry(day: String, cost: Double?, tokens: Int?) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    private static func losAngelesDate(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        var components = DateComponents()
        components.calendar = self.losAngelesCalendar
        components.timeZone = TimeZone(identifier: "America/Los_Angeles")
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return components.date!
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

    private static func isoDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static var losAngelesCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }
}
