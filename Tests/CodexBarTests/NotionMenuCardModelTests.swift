import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// The card is where the calendar-cycle resolution has to land. `ProviderPaceCapability` exposing the
/// right duration is not enough on its own: the card is also handed a precomputed `weeklyPace`, and
/// preferring it would score the billing period as a flat 30 days while the CLI scored the real month.
struct NotionMenuCardModelTests {
    /// 2026-02-08T00:00:00Z — 21 days before the cycle ends, 7 days into a 28-day February.
    private static let now = Date(timeIntervalSince1970: 1_770_508_800)
    /// 2026-03-01T00:00:00Z.
    private static let periodEnd = Date(timeIntervalSince1970: 1_772_323_200)

    private static func snapshot() -> UsageSnapshot {
        NotionUsageSnapshot(
            rateLimit: NotionCreditRateLimitStatus(
                status: "enforced",
                window: NotionRollingWindow(
                    creditType: nil,
                    scope: nil,
                    window: "6h",
                    used: 50,
                    limit: 100),
                resetsInSeconds: 3600,
                billingPeriodWindow: NotionBillingPeriodWindow(
                    creditType: nil,
                    scope: nil,
                    cadence: nil,
                    used: 40,
                    limit: 100,
                    periodEndMs: self.periodEnd.timeIntervalSince1970 * 1000),
                enforcement: nil),
            workspace: nil,
            account: nil,
            updatedAt: self.now)
            .toUsageSnapshot()
    }

    private static func model(weeklyPace: UsagePace?) throws -> UsageMenuCardView.Model {
        let metadata = try #require(ProviderDefaults.metadata[.notion])
        return UsageMenuCardView.Model.make(.init(
            provider: .notion,
            metadata: metadata,
            snapshot: Self.snapshot(),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
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
            weeklyPace: weeklyPace,
            now: Self.now))
    }

    @Test
    func `monthly bar paces against February, not a flat thirty days`() throws {
        let monthly = try #require(Self.snapshot().secondary)
        // What the store hands the card: a pace measured against the raw 30-day sentinel. Reusing it
        // would report 30% expected (9 of 30 days) instead of 25% (7 of February's 28).
        let sentinelPace = try #require(UsagePace.weekly(
            window: monthly,
            now: Self.now,
            defaultWindowMinutes: 10080))
        #expect((sentinelPace.expectedUsedPercent * 10).rounded() / 10 == 30)

        let metric = try #require(try Self.model(weeklyPace: sentinelPace).metrics.first { $0.id == "secondary" })

        #expect(metric.pacePercent == 25)
        #expect(metric.detailLeftText == "15% in deficit")
    }

    @Test
    func `monthly pace is identical whether or not a precomputed pace is supplied`() throws {
        let monthly = try #require(Self.snapshot().secondary)
        let sentinelPace = UsagePace.weekly(window: monthly, now: Self.now, defaultWindowMinutes: 10080)

        let withPace = try #require(try Self.model(weeklyPace: sentinelPace).metrics.first { $0.id == "secondary" })
        let withoutPace = try #require(try Self.model(weeklyPace: nil).metrics.first { $0.id == "secondary" })

        #expect(withPace.pacePercent == withoutPace.pacePercent)
        #expect(withPace.detailLeftText == withoutPace.detailLeftText)
    }

    @Test
    func `rolling bar carries a session pace`() throws {
        let metric = try #require(try Self.model(weeklyPace: nil).metrics.first { $0.id == "primary" })

        // Five of the six rolling hours elapsed against 50% used.
        #expect(metric.detailLeftText == "33% in reserve")
    }
}
