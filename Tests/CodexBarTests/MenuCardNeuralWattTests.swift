import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MenuCardNeuralWattTests {
    @Test
    func `model shows prepaid balance as pay as you go`() throws {
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

        #expect(model.metrics.isEmpty)
        let prepaid = try #require(model.providerCost)
        #expect(prepaid.title == "Pay-as-you-go")
        #expect(prepaid.spendLine.replacingOccurrences(of: "\u{00A0}", with: "") == "Balance: $51.00")
        #expect(model.creditsText == nil)
    }

    @Test
    func `model shows subscription quota and separate prepaid balance`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let subscription = NeuralWattSubscription(
            plan: "pro",
            status: "active",
            billingInterval: "month",
            currentPeriodStart: now.addingTimeInterval(-10 * 24 * 60 * 60),
            currentPeriodEnd: now.addingTimeInterval(20 * 24 * 60 * 60),
            autoRenew: true,
            kwhIncluded: 10,
            kwhUsed: 2.5,
            kwhRemaining: 7.5,
            inOverage: false)
        let snapshot = NeuralWattUsageSnapshot(
            creditsRemainingUSD: 0,
            totalCreditsUSD: 0,
            creditsUsedUSD: 0,
            accountingMethod: "energy",
            currentMonthCostUSD: nil,
            currentMonthEnergyKWh: nil,
            subscription: subscription,
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
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let primary = try #require(model.metrics.first)
        #expect(primary.title == "Subscription")
        #expect(primary.percent == 25)
        #expect(primary.detailText == "2.50 / 10 kWh")
        #expect(primary.statusText == nil)
        #expect(primary.resetText == "Resets in 20d")
        #expect(model.providerCost?.spendLine.replacingOccurrences(of: "\u{00A0}", with: "") == "Balance: $0.00")
    }
}
