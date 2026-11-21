import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct QoderTeamsOrgBalanceBehaviorTests {
    @MainActor
    @Test
    func `organization balance drives automatic selection and card detail`() throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .qoder)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100,
                windowMinutes: nil,
                resetsAt: now,
                resetDescription: "0 / 0 credits"),
            secondary: RateWindow(
                usedPercent: 24,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "1,200 / 5,000 credits"),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .qoder,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))

        #expect(descriptor.metadata.sessionLabel == "Credits")
        #expect(descriptor.metadata.weeklyLabel == "Balance")
        #expect(PercentWindow.weekly.providerLabel(provider: .qoder) == "Balance")

        let selected = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .qoder,
            snapshot: snapshot,
            supportsAverage: false,
            now: now)
        #expect(selected?.usedPercent == 24)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .qoder,
            metadata: descriptor.metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
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
            weeklyPace: nil,
            now: now))

        let secondary = try #require(model.metrics.first { $0.title == "Balance" })
        #expect(secondary.detailText == "1,200 / 5,000 credits")
        #expect(secondary.resetText == nil)
        #expect(!(secondary.detailText ?? "").hasPrefix("Resets"))
    }
}
