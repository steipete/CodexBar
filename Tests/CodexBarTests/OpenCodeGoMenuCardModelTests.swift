import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct OpenCodeGoMenuCardModelTests {
    @Test
    func `zen balance renders as optional balance`() throws {
        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 34, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            providerCost: ProviderCostSnapshot(
                used: 98.76,
                limit: 0,
                currencyCode: "USD",
                period: "Zen balance",
                updatedAt: now),
            updatedAt: now,
            identity: nil)
        let metadata = try #require(ProviderDefaults.metadata[.opencodego])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .opencodego,
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

        #expect(model.providerCost?.title == "Zen balance")
        #expect(model.providerCost?.spendLine == "Balance: $98.76")
        #expect(model.providerCost?.percentUsed == nil)
        #expect(model.providerCost?.percentLine == nil)
    }

    @Test
    func `required zen balance renders when optional usage is disabled`() throws {
        let now = Date()
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: ProviderCostSnapshot(
                used: 98.76,
                limit: 0,
                currencyCode: "USD",
                period: "Zen balance",
                updatedAt: now),
            updatedAt: now,
            identity: nil)
        let metadata = try #require(ProviderDefaults.metadata[.opencodego])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .opencodego,
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
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: false,
            now: now))

        #expect(model.providerCost?.title == "Zen balance")
        #expect(model.providerCost?.spendLine == "Balance: $98.76")
    }

    @Test
    func `subscription zen balance hides when optional usage is disabled`() throws {
        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 34, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            providerCost: ProviderCostSnapshot(
                used: 98.76,
                limit: 0,
                currencyCode: "USD",
                period: "Zen balance",
                updatedAt: now),
            updatedAt: now,
            identity: nil)
        let metadata = try #require(ProviderDefaults.metadata[.opencodego])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .opencodego,
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
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: false,
            now: now))

        #expect(model.providerCost == nil)
    }
}
