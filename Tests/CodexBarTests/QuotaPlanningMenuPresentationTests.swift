import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct QuotaPlanningMenuPresentationTests {
    @Test
    func `model decorates only the matching long window`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: Self.snapshot(now: now),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            quotaPlanningEstimates: ["secondary": Self.estimate(id: "secondary", value: 4)],
            now: now))

        #expect(model.metrics.first(where: { $0.id == "primary" })?.quotaPlanningText == nil)
        #expect(model.metrics.first(where: { $0.id == "secondary" })?.quotaPlanningText ==
            "Available full sessions: ≈4")
    }

    @Test
    func `shared decoration supports independent named quota groups`() {
        let metrics = [Self.metric(id: "group-a-weekly"), Self.metric(id: "group-b-weekly")]
        let decorated = UsageMenuCardView.Model.metricsByAddingQuotaPlanning(
            metrics,
            estimates: [
                "group-a-weekly": Self.estimate(id: "group-a-weekly", value: 1.25),
                "group-b-weekly": Self.estimate(id: "group-b-weekly", value: 8),
            ])

        #expect(decorated[0].quotaPlanningText == "Available full sessions: ≈1.3")
        #expect(decorated[1].quotaPlanningText == "Available full sessions: ≈8")
    }

    @Test
    func `small positive estimates remain visible`() throws {
        let estimate = Self.estimate(id: "secondary", value: 0.04)

        let text = try #require(UsageMenuCardView.Model.quotaPlanningText(for: estimate))

        #expect(text == "Available full sessions: ≈<0.1")
    }

    @Test
    func `number formatting follows the selected locale`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("de") {
            let estimate = Self.estimate(id: "secondary", value: 1.25)

            let text = try #require(UsageMenuCardView.Model.quotaPlanningText(for: estimate))

            #expect(text == "Verfügbare volle Sitzungen: ≈1,3")
        }
    }

    private static func snapshot(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 40,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 60,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(6 * 24 * 60 * 60),
                resetDescription: nil),
            updatedAt: now)
    }

    private static func metric(id: String) -> UsageMenuCardView.Model.Metric {
        .init(
            id: id,
            title: id,
            percent: 50,
            percentStyle: .left,
            resetText: nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: true)
    }

    private static func estimate(id: String, value: Double) -> QuotaPlanningEstimate {
        QuotaPlanningEstimate(
            pairID: "pair-\(id)",
            longMetricID: id,
            fundableFullSessionEquivalents: value,
            maximumFullSessionEquivalentsBeforeReset: 3,
            futureFullShortAllowanceCount: 2,
            longPercentPerFullShortAllowance: 5,
            reachability: .insufficientEvidence,
            shortResetAt: Date(timeIntervalSince1970: 1_800_010_000),
            longResetAt: Date(timeIntervalSince1970: 1_800_500_000))
    }
}
