import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardNeuralWattTests {
    @Test
    func `model shows credit balance as status text without reset wording`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = NeuralWattUsageSnapshot(
            creditsRemainingUSD: 51.00,
            totalCreditsUSD: 77.04,
            creditsUsedUSD: 26.04,
            accountingMethod: "energy",
            currentMonthCostUSD: 12.34,
            currentMonthEnergyKWh: 0.25,
            subscription: nil,
            keyAllowance: nil,
            rateLimitTier: "standard",
            updatedAt: now)
            .toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.neuralwatt])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .neuralwatt,
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

        let primary = try #require(model.metrics.first)
        #expect(primary.title == "Credits")
        let statusText = primary.statusText?.replacingOccurrences(of: "\u{00A0}", with: "")
        #expect(statusText == "$51.00 remaining of $77.04")
        #expect(primary.detailText == nil)
        #expect(primary.resetText == nil)
        #expect(model.metrics.contains { $0.title == "This month" } == false)
        #expect(model.metrics.allSatisfy { metric in
            metric.resetText?.localizedCaseInsensitiveContains("reset") != true
        })
    }
}
