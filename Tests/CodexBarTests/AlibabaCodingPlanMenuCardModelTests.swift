import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct AlibabaCodingPlanMenuCardModelTests {
    @Test
    func `monthly quota shows deficit and run out details`() throws {
        let now = Date(timeIntervalSince1970: 10_368_000) // 1970-05-01T00:00:00Z
        let reset = now.addingTimeInterval(6 * 24 * 3600)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: 5 * 60,
                resetsAt: now.addingTimeInterval(2 * 3600),
                resetDescription: "250 / 1000 used"),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(4 * 24 * 3600),
                resetDescription: "400 / 1000 used"),
            tertiary: RateWindow(
                usedPercent: 90,
                windowMinutes: 30 * 24 * 60,
                resetsAt: reset,
                resetDescription: "900 / 1000 used"),
            updatedAt: now,
            identity: nil)
        let metadata = try #require(ProviderDefaults.metadata[.alibaba])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .alibaba,
            metadata: metadata,
            snapshot: snapshot,
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
            now: now))

        #expect(model.metrics.map(\.title) == ["5-hour", "Weekly", "Monthly"])
        let monthly = try #require(model.metrics.first { $0.id == "tertiary" })
        #expect(monthly.percentLabel == "10% left")
        #expect(monthly.detailText == "900 / 1000 used")
        #expect(monthly.detailLeftText == "10% in deficit")
        #expect(monthly.detailRightText == "Runs out in 2d 16h")
        #expect(monthly.pacePercent == 20)
        #expect(monthly.paceOnTop == false)
    }

    @Test
    func `monthly pace uses thirty one day reset window`() throws {
        let now = try Self.date("2026-07-01T23:00:00Z")
        let reset = try Self.date("2026-08-01T00:00:00Z")
        let model = try Self.model(
            now: now,
            monthly: RateWindow(
                usedPercent: 10,
                windowMinutes: 30 * 24 * 60,
                resetsAt: reset,
                resetDescription: nil))

        let monthly = try #require(model.metrics.first { $0.id == "tertiary" })
        #expect(monthly.detailLeftText == "7% in deficit")
        #expect(monthly.detailRightText == "Runs out in 8d 15h")
    }

    @Test
    func `monthly pace uses twenty eight day reset window`() throws {
        let now = try Self.date("2026-02-02T00:00:00Z")
        let reset = try Self.date("2026-03-01T00:00:00Z")
        let model = try Self.model(
            now: now,
            monthly: RateWindow(
                usedPercent: 0,
                windowMinutes: 30 * 24 * 60,
                resetsAt: reset,
                resetDescription: nil))

        let monthly = try #require(model.metrics.first { $0.id == "tertiary" })
        #expect(monthly.detailLeftText == "4% in reserve")
        #expect(monthly.detailRightText == "Lasts until reset")
    }

    private static func model(now: Date, monthly: RateWindow) throws -> UsageMenuCardView.Model {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: monthly,
            updatedAt: now,
            identity: nil)
        let metadata = try #require(ProviderDefaults.metadata[.alibaba])

        return UsageMenuCardView.Model.make(.init(
            provider: .alibaba,
            metadata: metadata,
            snapshot: snapshot,
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
            now: now))
    }

    private static func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }
}
