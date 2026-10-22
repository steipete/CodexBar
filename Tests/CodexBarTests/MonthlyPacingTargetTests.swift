import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MonthlyPacingTargetTests {
    static let now = Date(timeIntervalSince1970: 1_770_508_800)
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test
    func `monthly allowance shows a daily target beside its existing pace`() throws {
        let metric = try #require(Self.model(window: Self.window()).metrics.first)
        #expect(metric.dailyTargetText == "≈ 2% / day to last until reset")
        #expect(metric.detailLeftText != nil)
    }

    @Test
    func `credit and request targets retain the allowance unit and existing details`() throws {
        let credit = try #require(Self.model(window: Self.window(limit: 61700, unit: "credits")).metrics.first)
        #expect(credit.dailyTargetText == "≈ 1,234 credits / day to last until reset")
        let request = try #require(Self.model(window: Self.window(limit: 150, unit: "requests")).metrics.first)
        #expect(request.dailyTargetText == "≈ 3 requests / day to last until reset")
    }

    @Test
    func `monthly monetary budgets use currency and keep the cost section`() throws {
        let cost = ProviderCostSnapshot(
            used: 58,
            limit: 100,
            currencyCode: "EUR",
            period: "Monthly",
            resetsAt: Self.now.addingTimeInterval(21 * 86400),
            updatedAt: Self.now)
        let section = try #require(Self.model(window: nil, cost: cost).providerCost)
        #expect(section.dailyTargetText == "≈ €2.00 / day to last until reset")
        #expect(section.spendLine.contains("58.00"))
        #expect(Self.model(window: nil, cost: cost, paceVisible: false).providerCost?.dailyTargetText == nil)
    }

    @Test
    func `spend-only monthly cards require the reported reset instead of an inferred one`() {
        let reported = ProviderCostSnapshot(
            used: 58,
            limit: 100,
            currencyCode: "USD",
            period: "Monthly cap",
            resetsAt: Self.now.addingTimeInterval(21 * 86400),
            updatedAt: Self.now)
        let model = Self.model(window: nil, cost: reported, provider: .claude)
        #expect(model.providerCost == nil)
        #expect(model.metrics.first?.dailyTargetText == "≈ $2.00 / day to last until reset")
        let missing = ProviderCostSnapshot(
            used: 58,
            limit: 100,
            currencyCode: "USD",
            period: "Monthly cap",
            updatedAt: Self.now)
        #expect(Self.model(window: nil, cost: missing, provider: .claude).metrics.first?.dailyTargetText == nil)
    }

    @Test
    func `last day assigns the whole remainder and overage has zero target`() {
        let window = Self.window(reset: Self.now.addingTimeInterval(3600), limit: 100, unit: "credits")
        #expect(Self.model(window: window).metrics.first?.dailyTargetText == "≈ 42 credits / day to last until reset")
        let exhausted = Self.window(used: 125, reset: Self.now.addingTimeInterval(3600))
        #expect(Self.model(window: exhausted).metrics.first?.dailyTargetText == "≈ 0% / day to last until reset")
    }

    @Test
    func `local calendar includes today and partial reset day across daylight saving`() throws {
        var calendar = Self.utc
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        // March 7 23:30 PST to March 9 00:30 PDT spans three usable calendar dates, but only 24 hours.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-03-08T07:30:00Z"))
        let reset = try #require(ISO8601DateFormatter().date(from: "2026-03-09T07:30:00Z"))
        let metric = Self.model(
            window: Self.window(reset: reset, minutes: 28 * 1440 - 60), now: now, calendar: calendar).metrics.first
        #expect(metric?.dailyTargetText == "≈ 14% / day to last until reset")
        // Reset precisely at local midnight gives no usable time on March 9.
        let midnight = calendar.startOfDay(for: reset)
        let beforeMidnight = Self.model(
            window: Self.window(reset: midnight), now: now, calendar: calendar).metrics.first
        #expect(beforeMidnight?.dailyTargetText == "≈ 21% / day to last until reset")
    }

    @Test
    func `missing expired unknown and nonmonthly windows have no target`() {
        for window in [
            Self.window(reset: nil), Self.window(reset: Self.now),
            Self.window(reset: Self.now.addingTimeInterval(-1)),
            Self.window(used: -1), Self.window(limit: .infinity, unit: "credits"),
            Self.window(minutes: 10080), Self.window(limit: 100, unit: nil),
            Self.window(limit: 100, unit: "unknown"),
            RateWindow(
                usedPercent: 0,
                windowMinutes: 43200,
                resetsAt: Self.now.addingTimeInterval(86400),
                resetDescription: nil,
                isSyntheticPlaceholder: true),
        ] {
            #expect(Self.model(window: window).metrics.first?.dailyTargetText == nil)
        }
        #expect(Self.model(window: Self.window(), paceVisible: false).metrics.first?.dailyTargetText == nil)
    }

    @Test
    func `unknown extra-window usage keeps reset context without a daily target`() throws {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(id: "monthly", title: "Monthly", window: Self.window(), usageKnown: false),
            ],
            updatedAt: Self.now)
        let metric = try #require(Self.model(window: nil, snapshot: snapshot).metrics.first)
        #expect(metric.statusText?.contains("21d") == true)
        #expect(metric.dailyTargetText == nil)
    }

    @Test
    func `allowance metadata survives persistence and monthly reset resolution`() throws {
        let window = Self.window(limit: 250, unit: "credits")
        let restored = try JSONDecoder().decode(RateWindow.self, from: JSONEncoder().encode(window))
        #expect(restored == window)
        let resolved = ProviderPaceCapability.calendarMonthResetWindow.resolvedResetWindowForPace(restored)
        #expect(resolved.quotaLimit == 250)
        #expect(resolved.quotaUnit == "credits")
        let missingReset = Self.window(reset: nil, limit: 125, unit: "credits")
        let backfilled = missingReset.backfillingResetTime(from: window, now: Self.now)
        #expect(backfilled.quotaLimit == 125)
        #expect(backfilled.quotaUnit == "credits")
    }

    static func window(
        used: Double = 58,
        reset: Date? = Self.now.addingTimeInterval(21 * 86400),
        minutes: Int = 43200,
        limit: Double? = nil,
        unit: String? = nil) -> RateWindow
    {
        RateWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: reset,
            resetDescription: nil,
            quotaLimit: limit,
            quotaUnit: unit)
    }

    static func model(
        window: RateWindow?,
        cost: ProviderCostSnapshot? = nil,
        snapshot: UsageSnapshot? = nil,
        provider: UsageProvider = .notion,
        now: Date = Self.now,
        calendar: Calendar = Self.utc,
        paceVisible: Bool = true) -> UsageMenuCardView.Model
    {
        UsageMenuCardView.Model.make(.init(
            provider: provider,
            metadata: ProviderDefaults.metadata[provider]!,
            snapshot: snapshot ?? UsageSnapshot(primary: nil, secondary: window, providerCost: cost, updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            paceVisible: paceVisible,
            now: now), calendar: calendar)
    }
}
