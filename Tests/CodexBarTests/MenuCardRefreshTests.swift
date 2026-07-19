import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardRefreshTests {
    private static func makeModel(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        isRefreshing: Bool,
        now: Date) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[provider])
        return UsageMenuCardView.Model.make(.init(
            provider: provider,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: isRefreshing,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
    }

    @Test
    func `background refresh keeps quota timing current`() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        for provider in [UsageProvider.claude, .codex] {
            let snapshot = UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 21,
                    windowMinutes: 300,
                    resetsAt: updatedAt.addingTimeInterval(4 * 60 * 60 + 40 * 60),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: provider,
                    accountEmail: nil,
                    accountOrganization: nil,
                    loginMethod: "Pro"))
            let completedModel = try Self.makeModel(
                provider: provider,
                snapshot: snapshot,
                isRefreshing: false,
                now: updatedAt)
            let refreshingModel = try Self.makeModel(
                provider: provider,
                snapshot: snapshot,
                isRefreshing: true,
                now: updatedAt.addingTimeInterval(10 * 60))

            let completedMetric = try #require(completedModel.metrics.first)
            let refreshingMetric = try #require(refreshingModel.metrics.first)
            #expect(refreshingModel.subtitleText == "Refreshing…")
            #expect(refreshingMetric.percentLabel == completedMetric.percentLabel)
            #expect(completedMetric.resetText == "Resets in 4h 40m")
            #expect(refreshingMetric.resetText == "Resets in 4h 30m")
            #expect(refreshingMetric.detailLeftText != completedMetric.detailLeftText)
            #expect(refreshingMetric.detailRightText != completedMetric.detailRightText)
            #expect(refreshingMetric.pacePercent != completedMetric.pacePercent)
        }
    }
}
