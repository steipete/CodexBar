import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Antigravity reports one weekly bucket per model family and surfaces whichever family is most
/// constrained, so stored reset observations name different quotas. Using them as window boundaries
/// produced "Previous window" rows minutes long that no daily spend could be attributed to, which
/// rendered as an em dash beside a real current window.
struct AntigravityQuotaWindowBoundaryTests {
    @Test
    func `family resets minutes apart would otherwise manufacture sliver windows`() throws {
        let fixture = try Fixture()
        let week = TimeInterval(CostUsageTokenSnapshot.quotaWeekMinutes * 60)

        let withObservations = CostUsageTokenSnapshot.quotaWeekBoundaries(
            liveNextReset: fixture.liveReset,
            observedNextResets: fixture.observations.map(\.resetsAt),
            resetObservations: fixture.observations,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            now: fixture.now,
            calendar: fixture.calendar)
        // The defect: consecutive boundaries only minutes apart, which no daily bucket can fill.
        #expect(Self.spans(withObservations).contains { $0 < week })

        let liveResetOnly = CostUsageTokenSnapshot.quotaWeekBoundaries(
            liveNextReset: fixture.liveReset,
            observedNextResets: [],
            resetObservations: [],
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            now: fixture.now,
            calendar: fixture.calendar)
        // Antigravity's path: nominal weekly strides only, so every window is a real quota week.
        #expect(!liveResetOnly.isEmpty)
        #expect(Self.spans(liveResetOnly).allSatisfy { $0 == week })
    }

    @Test
    func `Antigravity renders only full-week quota windows`() throws {
        let windows = try #require(Fixture().model().inlineUsageDashboard?.quotaWindows)

        #expect(!windows.isEmpty)
        #expect(windows.map(\.title).first == "Current window")
        // A sliver window would render as a same-day time range such as "12:58 PM – 1:04 PM".
        // A real quota week always spans two distinct dates.
        #expect(!windows.contains { $0.range.contains("12:58") || $0.range.contains("11:58") })
    }

    @Test
    func `Antigravity ignores observed resets while Codex still honors them`() {
        #expect(UsageMenuCardView.Model.menuCardPresentation(for: .antigravity)
            .ignoresObservedQuotaResetBoundaries)
        #expect(!UsageMenuCardView.Model.menuCardPresentation(for: .codex)
            .ignoresObservedQuotaResetBoundaries)
    }

    private static func spans(_ boundaries: [Date]) -> [TimeInterval] {
        zip(boundaries, boundaries.dropFirst()).map { $1.timeIntervalSince($0) }
    }

    private struct Fixture {
        let calendar: Calendar
        let now: Date
        let liveReset: Date
        let observations: [CostUsageQuotaResetObservation]

        init() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            self.calendar = calendar
            self.now = try Self.date(calendar, 20, 12, 0)
            self.liveReset = try Self.date(calendar, 23, 13, 4)
            // Three family resets minutes apart, exactly the shape that produced the empty rows.
            let firstCapture = try Self.date(calendar, 16, 11, 50)
            let firstReset = try Self.date(calendar, 16, 11, 58)
            let secondCapture = try Self.date(calendar, 16, 12, 0)
            let secondReset = try Self.date(calendar, 16, 12, 3)
            let thirdCapture = try Self.date(calendar, 16, 12, 30)
            let thirdReset = try Self.date(calendar, 16, 12, 58)
            self.observations = [
                CostUsageQuotaResetObservation(capturedAt: firstCapture, resetsAt: firstReset),
                CostUsageQuotaResetObservation(capturedAt: secondCapture, resetsAt: secondReset),
                CostUsageQuotaResetObservation(capturedAt: thirdCapture, resetsAt: thirdReset),
            ]
        }

        private static func date(_ calendar: Calendar, _ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(
                timeZone: calendar.timeZone, year: 2026, month: 9, day: day, hour: hour, minute: minute)))
        }

        func model() throws -> UsageMenuCardView.Model {
            let metadata = try #require(ProviderDefaults.metadata[.antigravity])
            let window = NamedRateWindow(
                id: "antigravity-quota-summary-gemini",
                title: "Gemini",
                window: RateWindow(
                    usedPercent: 40,
                    windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
                    resetsAt: self.liveReset,
                    resetDescription: nil))
            return UsageMenuCardView.Model.make(.init(
                provider: .antigravity,
                metadata: metadata,
                snapshot: UsageSnapshot(
                    primary: nil,
                    secondary: nil,
                    extraRateWindows: [window],
                    updatedAt: self.now),
                credits: nil,
                creditsError: nil,
                dashboardError: nil,
                tokenSnapshot: self.snapshot(),
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: true,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: false,
                costUsageBucketCalendar: self.calendar,
                now: self.now,
                observedWeeklyResets: self.observations))
        }

        private func snapshot() -> CostUsageTokenSnapshot {
            CostUsageTokenSnapshot(
                sessionTokens: 1000,
                sessionCostUSD: 10,
                last30DaysTokens: 1400,
                last30DaysCostUSD: 14,
                historyDays: 30,
                costProvenance: .listPriceEstimate,
                daily: [
                    // Usage on the day the family resets fall in: this is what makes the spurious
                    // micro-windows overlap a real day and render as an em dash.
                    CostUsageDailyReport.Entry(
                        date: "2026-09-16",
                        inputTokens: 300,
                        outputTokens: 100,
                        totalTokens: 400,
                        costUSD: 4,
                        modelsUsed: ["gemini-3.8-flash"],
                        modelBreakdowns: [
                            CostUsageDailyReport.ModelBreakdown(
                                modelName: "gemini-3.8-flash", costUSD: 4, totalTokens: 400),
                        ]),
                    CostUsageDailyReport.Entry(
                        date: "2026-09-18",
                        inputTokens: 800,
                        outputTokens: 200,
                        totalTokens: 1000,
                        costUSD: 10,
                        modelsUsed: ["gemini-3.8-flash"],
                        modelBreakdowns: [
                            CostUsageDailyReport.ModelBreakdown(
                                modelName: "gemini-3.8-flash", costUSD: 10, totalTokens: 1000),
                        ]),
                ],
                updatedAt: self.now)
        }
    }
}
