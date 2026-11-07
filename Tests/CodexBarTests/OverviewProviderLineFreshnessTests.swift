import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct OverviewProviderLineFreshnessTests {
    private static let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func claudeModel(
        error: String,
        quotaRefreshFailed: Bool,
        subtitleOverride: String? = nil) throws -> UsageMenuCardView.Model
    {
        try UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: #require(ProviderDefaults.metadata[.claude]),
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 95,
                    windowMinutes: 300,
                    resetsAt: Self.now.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Self.now),
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: error,
            quotaRefreshFailed: quotaRefreshFailed,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            subtitleOverride: subtitleOverride,
            hidePersonalInfo: true,
            paceVisible: false,
            now: Self.now))
    }

    private func codexModel(
        quotaRefreshFailed: Bool,
        dashboardRefreshFailed: Bool) throws -> UsageMenuCardView.Model
    {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "codex@example.test",
            accountOrganization: nil,
            loginMethod: nil)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Self.now,
            identity: identity)
        let quotaError = quotaRefreshFailed ? "Synthetic quota refresh failure" : nil
        let dashboard = OpenAIDashboardSnapshot(
            signedInEmail: "codex@example.test",
            codeReviewRemainingPercent: 5,
            codeReviewLimit: RateWindow(
                usedPercent: 95,
                windowMinutes: nil,
                resetsAt: Self.now.addingTimeInterval(3600),
                resetDescription: nil),
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Self.now)
        let projection = CodexConsumerProjection.make(
            surface: .liveCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: quotaError,
                liveCredits: nil,
                rawCreditsError: nil,
                liveDashboard: dashboard,
                rawDashboardError: dashboardRefreshFailed ? "Synthetic dashboard refresh failure" : nil,
                dashboardAttachmentAuthorized: true,
                dashboardRequiresLogin: false,
                now: Self.now))
        return try UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: #require(ProviderDefaults.metadata[.codex]),
            snapshot: snapshot,
            codexProjection: projection,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.test", plan: nil),
            isRefreshing: false,
            lastError: quotaError,
            quotaRefreshFailed: quotaRefreshFailed,
            dashboardRefreshFailed: dashboardRefreshFailed,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            paceVisible: false,
            now: Self.now))
    }

    private func syntheticCreditModel() throws -> UsageMenuCardView.Model {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "business@example.test",
            accountOrganization: "Synthetic team",
            loginMethod: "business")
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Self.now, identity: identity)
        let credits = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: Self.now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 95,
                limit: 100,
                remainingPercent: 5,
                resetsAt: Self.now.addingTimeInterval(86400),
                updatedAt: Self.now))
        let projection = CodexConsumerProjection.make(
            surface: .overrideCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: "Synthetic quota refresh failure",
                liveCredits: credits,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: Self.now))
        return try UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: #require(ProviderDefaults.metadata[.codex]),
            snapshot: snapshot,
            codexProjection: projection,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "business@example.test", plan: "business"),
            isRefreshing: false,
            lastError: "Synthetic quota refresh failure",
            quotaRefreshFailed: true,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            paceVisible: false,
            now: Self.now))
    }

    private func barTint(_ model: UsageMenuCardView.Model, metric: UsageMenuCardView.Model.Metric) -> Color {
        MetricRow(
            metric: metric,
            layoutMetric: metric,
            title: metric.title,
            progressColor: model.progressColor,
            isRetainedMeasurement: model.showsRetainedMeasurement).barTint
    }

    @Test
    func `retained code review stays stale when the quota refresh succeeded`() throws {
        let model = try self.codexModel(quotaRefreshFailed: false, dashboardRefreshFailed: true)
        let review = try #require(model.metrics.first { $0.id == "code-review" })
        #expect(model.subtitleStyle == .info)
        #expect(!model.showsRetainedMeasurement)
        #expect(review.retainedMeasurementOverride == true)
        #expect(self.barTint(model, metric: review) == UsageMenuCardView.Model.staleProgressColor)

        let line = OverviewProviderLine(id: "codex", model: model)
        #expect(line.remainingPercent == 5)
        #expect(line.status == .stale)
        #expect(line.caption == L("stale data"))
        #expect(!line.captionIsCritical)
        #expect(line.urgencyBand != 0)
    }

    @Test
    func `fresh code review remains critical when the quota refresh failed`() throws {
        let model = try self.codexModel(quotaRefreshFailed: true, dashboardRefreshFailed: false)
        let review = try #require(model.metrics.first { $0.id == "code-review" })
        #expect(model.subtitleStyle == .error)
        #expect(model.showsRetainedMeasurement)
        #expect(review.retainedMeasurementOverride == false)
        #expect(self.barTint(model, metric: review) == model.progressColor)

        let line = OverviewProviderLine(id: "codex", model: model)
        #expect(line.remainingPercent == 5)
        #expect(line.status == .critical)
        #expect(line.caption == review.title)
        #expect(line.urgencyBand == 0)
    }

    @Test(arguments: ["Fallback succeeded", "Synthetic Claude account switch failure"])
    func `fresh quota keeps its warning despite an error subtitle`(diagnostic: String) throws {
        let model = try self.claudeModel(error: diagnostic, quotaRefreshFailed: false)
        let quota = try #require(model.metrics.first)
        #expect(model.subtitleStyle == .error)
        #expect(!model.showsRetainedMeasurement)
        #expect(self.barTint(model, metric: quota) == model.progressColor)

        let line = OverviewProviderLine(id: "claude", model: model)
        #expect(line.remainingPercent == 5)
        #expect(line.status == .critical)
        #expect(line.caption == quota.title)
        #expect(line.urgencyBand == 0)
    }

    @Test
    func `account subtitle cannot hide a retained quota`() throws {
        let model = try self.claudeModel(
            error: "Synthetic quota refresh failure",
            quotaRefreshFailed: true,
            subtitleOverride: "Synthetic work account")
        #expect(model.subtitleStyle == .info)
        #expect(model.showsRetainedMeasurement)

        let line = OverviewProviderLine(id: "claude", model: model)
        #expect(line.remainingPercent == 5)
        #expect(line.status == .stale)
        #expect(line.caption == L("stale data"))
        #expect(line.urgencyBand != 0)
    }

    @Test
    func `independently refreshed synthetic credits keep their warning after quota failure`() throws {
        let model = try self.syntheticCreditModel()
        let credit = try #require(model.metrics.first)
        #expect(model.showsRetainedMeasurement)
        #expect(credit.isSyntheticCreditLane)
        #expect(credit.retainedMeasurementOverride == nil)
        #expect(self.barTint(model, metric: credit) == model.progressColor)

        let line = OverviewProviderLine(id: "codex", model: model)
        #expect(line.remainingPercent == 5)
        #expect(line.status == .critical)
        #expect(line.caption == credit.title)
    }

    @Test(arguments: [false, true])
    func `an explicit synthetic credit refresh outcome wins over the quota outcome`(retained: Bool) throws {
        var model = try self.syntheticCreditModel()
        let original = try #require(model.metrics.first)
        model.metrics = [UsageMenuCardView.Model.Metric(
            id: original.id,
            title: original.title,
            percent: original.percent,
            percentStyle: original.percentStyle,
            resetText: original.resetText,
            detailText: original.detailText,
            detailLeftText: original.detailLeftText,
            detailRightText: original.detailRightText,
            pacePercent: original.pacePercent,
            paceOnTop: original.paceOnTop,
            isSyntheticCreditLane: true,
            retainedMeasurementOverride: retained)]

        let line = OverviewProviderLine(id: "codex", model: model)
        #expect(line.remainingPercent == 5)
        #expect(line.status == (retained ? .stale : .critical))
        #expect(line.caption == (retained ? L("stale data") : original.title))
    }
}
