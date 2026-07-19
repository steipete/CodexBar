import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct GrokMenuCardModelTests {
    @Test
    func `weekly CLI quota shows projection and pace marker`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 50,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(4 * 24 * 3600),
                resetDescription: nil))

        let metric = try #require(model.metrics.first { $0.id == "primary" })
        #expect(metric.title == "Weekly")
        #expect(metric.detailLeftText == "7% in deficit")
        #expect(metric.detailRightText == "Runs out in 3d")
        #expect(metric.pacePercent != nil)
        #expect(metric.paceOnTop == false)
    }

    @Test
    func `weekly web quota infers projection from reset date`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 50,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(4 * 24 * 3600),
                resetDescription: nil))

        let metric = try #require(model.metrics.first { $0.id == "primary" })
        #expect(metric.title == "Weekly")
        #expect(metric.detailLeftText == "7% in deficit")
        #expect(metric.detailRightText == "Runs out in 3d")
        #expect(metric.pacePercent != nil)
        #expect(metric.paceOnTop == false)
    }

    @Test
    func `weekly web quota beyond default duration does not show projection`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 50,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(8 * 24 * 3600),
                resetDescription: nil))

        let metric = try #require(model.metrics.first { $0.id == "primary" })
        #expect(metric.title == "Weekly")
        #expect(metric.detailLeftText == nil)
        #expect(metric.detailRightText == nil)
        #expect(metric.pacePercent == nil)
    }

    @Test
    func `monthly quota does not show weekly projection`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 50,
                windowMinutes: 30 * 24 * 60,
                resetsAt: now.addingTimeInterval(20 * 24 * 3600),
                resetDescription: nil))

        let metric = try #require(model.metrics.first { $0.id == "primary" })
        #expect(metric.title == "Monthly")
        #expect(metric.detailLeftText == nil)
        #expect(metric.detailRightText == nil)
        #expect(metric.pacePercent == nil)
    }

    @Test
    func `unclassified quota does not show weekly projection`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 50,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(2 * 24 * 3600),
                resetDescription: nil))

        let metric = try #require(model.metrics.first { $0.id == "primary" })
        #expect(metric.title == "Credits")
        #expect(metric.detailLeftText == nil)
        #expect(metric.detailRightText == nil)
        #expect(metric.pacePercent == nil)
    }

    private static func model(now: Date, window: RateWindow) throws -> UsageMenuCardView.Model {
        let metadata = try #require(ProviderDefaults.metadata[.grok])
        let snapshot = UsageSnapshot(
            primary: window,
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: nil)
        return UsageMenuCardView.Model.make(.init(
            provider: .grok,
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
}
