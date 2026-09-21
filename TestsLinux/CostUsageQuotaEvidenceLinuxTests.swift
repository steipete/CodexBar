import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageQuotaEvidenceLinuxTests {
    @Test
    func `redeemed reset cancels a superseded future reset even after its deadline`() throws {
        let banked = Self.date("2026-07-16T18:00:00Z")
        let cancelled = Self.date("2026-07-18T15:00:00Z")
        let next = Self.date("2026-07-23T18:00:00Z")
        let snapshot = Self.snapshot()
        for now in [Self.date("2026-07-17T12:00:00Z"), Self.date("2026-07-19T12:00:00Z")] {
            let current = try #require(snapshot.quotaWeekSummaries(
                resetAt: next,
                observedNextResets: [cancelled],
                observedResetInstants: [banked],
                now: now,
                calendar: Self.calendar).first)
            #expect(current.start == banked)
            #expect(current.totalCostUSD == 4)
            #expect(current.totalTokens == 400)
        }
    }

    @Test
    func `missing reset metadata does not fabricate quota summaries`() {
        #expect(Self.snapshot().quotaWeekSummaries(resetAt: nil, calendar: Self.calendar).isEmpty)
    }

    @Test
    func `forecast observation chronology cancels an early replacement without credit inventory`() throws {
        let next = Self.date("2026-07-23T18:00:00Z")
        let observations: [CostUsageQuotaResetObservation] = [
            .init(capturedAt: Self.date("2026-07-15T12:00:00Z"), resetsAt: Self.date("2026-07-18T15:00:00Z")),
            .init(capturedAt: Self.date("2026-07-16T18:01:00Z"), resetsAt: next),
        ]
        let current = try #require(Self.snapshot().quotaWeekSummaries(
            resetAt: next, resetObservations: observations.reversed(), calendar: Self.calendar).first)
        #expect(current.start == Self.date("2026-07-16T18:00:00Z"))
        #expect(current.totalCostUSD == 4)
        #expect(current.boundariesAreEstimated)
    }

    @Test
    func `early replacement cancels every alias in a gradually drifting forecast`() throws {
        let initialCapture = Self.date("2026-07-15T12:00:00Z")
        let initialReset = Self.date("2026-07-18T15:00:00Z")
        let next = Self.date("2026-07-23T18:00:00Z")
        var observations = (0..<20).map { index in
            CostUsageQuotaResetObservation(
                capturedAt: initialCapture.addingTimeInterval(Double(index) * 60),
                resetsAt: initialReset.addingTimeInterval(Double(index) * 60))
        }
        observations.append(.init(capturedAt: Self.date("2026-07-16T18:01:00Z"), resetsAt: next))
        for input in [observations, Array(observations.reversed())] {
            let current = try #require(Self.snapshot().quotaWeekSummaries(
                resetAt: next, resetObservations: input, calendar: Self.calendar).first)
            #expect(current.start == Self.date("2026-07-16T18:00:00Z"))
            #expect(current.totalCostUSD == 4)
        }
    }

    @Test
    func `known cancelled live forecast is not advanced into a fabricated schedule`() {
        #expect(Self.snapshot().quotaWeekSummaries(
            resetAt: Self.date("2026-07-18T15:00:00Z"),
            observedResetInstants: [Self.date("2026-07-16T18:00:00Z")],
            calendar: Self.calendar).isEmpty)
    }

    @Test
    func `observed rollover confirms a boundary without cancelling its predecessor`() throws {
        let reset = Self.date("2026-07-18T15:00:00Z")
        let next = Self.date("2026-07-25T15:00:00Z")
        let current = try #require(Self.snapshot().quotaWeekSummaries(
            resetAt: next,
            resetObservations: [
                .init(capturedAt: Self.date("2026-07-17T12:00:00Z"), resetsAt: reset),
                .init(capturedAt: Self.date("2026-07-18T15:01:00Z"), resetsAt: next),
            ], calendar: Self.calendar).first)
        #expect(current.start == reset)
        #expect(!current.boundariesAreEstimated)
    }

    @Test
    func `exact redeemed reset one minute after an official reset remains a separate edge`() throws {
        let official = Self.date("2026-07-18T15:00:00Z")
        let banked = Self.date("2026-07-18T15:01:00Z")
        let snapshot = Self.snapshot(slices: [
            .init(timestamp: official.addingTimeInterval(30), totalTokens: 100, costUSD: 1),
            .init(timestamp: banked, totalTokens: 200, costUSD: 2),
        ])
        let rows = snapshot.quotaWeekSummaries(
            resetAt: Self.date("2026-07-25T15:01:00Z"),
            observedNextResets: [official],
            observedResetInstants: [banked],
            calendar: Self.calendar)
        let current = try #require(rows.first)
        #expect(current.start == banked)
        #expect(current.totalCostUSD == 2)
        #expect(rows[1].start == official)
        #expect(rows[1].totalCostUSD == 1)
    }

    @Test
    func `reset date jitter does not cancel the week that began with a redeemed credit`() throws {
        let current = try #require(Self.snapshot().quotaWeekSummaries(
            resetAt: Self.date("2026-07-23T17:59:30Z"),
            observedResetInstants: [Self.date("2026-07-16T18:00:00Z")],
            calendar: Self.calendar).first)
        #expect(current.totalCostUSD == 4)
    }

    @Test
    func `future observations and reset credits cannot change historical projection`() throws {
        let current = try #require(Self.snapshot().quotaWeekSummaries(
            resetAt: Self.date("2026-07-23T18:00:00Z"),
            observedResetInstants: [Self.date("2026-07-20T10:00:00Z")],
            resetObservations: [.init(
                capturedAt: Self.date("2026-07-20T10:00:00Z"), resetsAt: Self.date("2026-07-27T10:00:00Z"))],
            calendar: Self.calendar).first)
        #expect(current.start == Self.date("2026-07-16T18:00:00Z"))
        #expect(current.totalCostUSD == 4)
    }

    @Test
    func `unassignable daily residual marks both adjacent window totals partial`() {
        let snapshot = Self.snapshot(
            daily: [Self.entry(tokens: 900, cost: 9)],
            slices: [
                .init(timestamp: Self.date("2026-07-17T14:00:00Z"), totalTokens: 200, costUSD: 2),
                .init(timestamp: Self.date("2026-07-17T16:00:00Z"), totalTokens: 400, costUSD: 4),
            ])
        let rows = snapshot.quotaWeekSummaries(
            resetAt: Self.date("2026-07-24T15:00:00Z"), calendar: Self.calendar)
        #expect(rows[0].totalCostUSD == 4)
        #expect(rows[1].totalCostUSD == 2)
        for row in rows.prefix(2) {
            #expect(!row.tokensAreComplete)
            #expect(!row.costIsComplete)
        }
    }

    @Test
    func `unknown exact price retains all tokens but marks only cost partial`() throws {
        let current = try #require(Self.snapshot(slices: [
            .init(timestamp: Self.date("2026-07-17T10:00:00Z"), totalTokens: 400, costUSD: 4),
            .init(timestamp: Self.date("2026-07-17T11:00:00Z"), totalTokens: 200, costUSD: nil),
        ]).quotaWeekSummaries(resetAt: Self.date("2026-07-23T18:00:00Z"), calendar: Self.calendar).first)
        #expect(current.totalTokens == 600)
        #expect(current.tokensAreComplete)
        #expect(current.totalCostUSD == 4)
        #expect(!current.costIsComplete)
    }

    @Test
    func `daily model without a price marks a retained daily subtotal partial`() throws {
        let daily = Self.entry(tokens: 600, cost: 4, breakdowns: [
            .init(modelName: "priced-model", costUSD: 4, totalTokens: 400),
            .init(modelName: "unpriced-model", costUSD: nil, totalTokens: 200),
        ])
        let current = try #require(Self.snapshot(daily: [daily], slices: []).quotaWeekSummaries(
            resetAt: Self.date("2026-07-23T18:00:00Z"), calendar: Self.calendar).first)
        #expect(current.totalCostUSD == 4)
        #expect(!current.costIsComplete)
        #expect(current.tokensAreComplete)
    }

    @Test
    func `complete contained daily fallback is not marked partial for missing exact slices`() throws {
        let current = try #require(Self.snapshot(daily: [Self.entry(tokens: 900, cost: 9)]).quotaWeekSummaries(
            resetAt: Self.date("2026-07-23T18:00:00Z"), calendar: Self.calendar).first)
        #expect(current.totalCostUSD == 9)
        #expect(current.costIsComplete)
        #expect(current.tokensAreComplete)
    }

    @Test
    func `unfinished scan and current window before coverage both mark totals partial`() throws {
        for snapshot in [Self.snapshot(coverage: false), Self.snapshot(historyDays: 2)] {
            let current = try #require(snapshot.quotaWeekSummaries(
                resetAt: Self.date("2026-07-23T18:00:00Z"), calendar: Self.calendar).first)
            #expect(current.totalCostUSD == 4)
            #expect(!current.costIsComplete)
            #expect(!current.tokensAreComplete)
        }
    }

    @Test
    func `old finite observations do not expand the displayed history without bound`() throws {
        let boundaries = CostUsageTokenSnapshot.quotaWeekBoundaries(
            liveNextReset: Self.date("2026-07-23T18:00:00Z"),
            observedNextResets: [.distantPast],
            weekCount: 4,
            now: Self.date("2026-07-19T12:00:00Z"),
            calendar: Self.calendar)
        #expect(boundaries.count <= 8)
        #expect(try #require(boundaries.first) > Self.date("2026-06-01T00:00:00Z"))
    }

    @Test
    func `two explicit nearby resets survive and own only their half open interval`() {
        let first = Self.date("2026-07-18T15:00:00Z")
        let second = first.addingTimeInterval(60)
        let rows = Self.snapshot(slices: [
            .init(timestamp: first, totalTokens: 100, costUSD: 1),
            .init(timestamp: second, totalTokens: 200, costUSD: 2),
        ]).quotaWeekSummaries(
            resetAt: second.addingTimeInterval(604_800),
            observedResetInstants: [first, second],
            calendar: Self.calendar)
        #expect(rows[0].start == second)
        #expect(rows[0].totalCostUSD == 2)
        #expect(rows[1].start == first)
        #expect(rows[1].end == second)
        #expect(rows[1].totalCostUSD == 1)
        #expect(!rows[1].boundariesAreEstimated)
    }

    @Test(arguments: [false, true])
    func `incomplete Claude requests retain known quota subtotals with partial coverage`(_ separateDay: Bool) throws {
        let partial = CostUsageDailyReport.Entry(
            date: separateDay ? "2026-07-18" : "2026-07-17",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: separateDay ? nil : 400,
            costUSD: separateDay ? nil : 4,
            modelsUsed: ["fixture-model"],
            modelBreakdowns: [.init(
                modelName: "fixture-model",
                costUSD: separateDay ? nil : 4,
                totalTokens: separateDay ? nil : 400,
                incompleteRequestCount: 1)])
        let daily = separateDay ? [Self.entry(tokens: 400, cost: 4), partial] : [partial]
        let current = try #require(Self.snapshot(daily: daily).quotaWeekSummaries(
            resetAt: Self.date("2026-07-23T18:00:00Z"), calendar: Self.calendar).first)
        #expect(current.totalTokens == 400)
        #expect(current.totalCostUSD == 4)
        #expect(!current.tokensAreComplete)
        #expect(!current.costIsComplete)
    }

    private static func snapshot(
        coverage: Bool = true,
        historyDays: Int = 30,
        daily: [CostUsageDailyReport.Entry] = [],
        slices: [CostUsageTimedEntry]? = nil) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 400,
            last30DaysCostUSD: 4,
            historyDays: historyDays,
            historyCoverageIsEstablished: coverage,
            daily: daily,
            quotaSlices: slices ?? [.init(
                timestamp: self.date("2026-07-17T10:00:00Z"), totalTokens: 400, costUSD: 4)],
            updatedAt: self.date("2026-07-19T12:00:00Z"))
    }

    private static func entry(
        tokens: Int,
        cost: Double,
        breakdowns: [CostUsageDailyReport.ModelBreakdown]? = nil) -> CostUsageDailyReport.Entry
    {
        .init(
            date: "2026-07-17",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: breakdowns)
    }

    private static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
