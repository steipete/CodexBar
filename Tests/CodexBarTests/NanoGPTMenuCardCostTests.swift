import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct NanoGPTMenuCardCostTests {
    private func makeModel(
        used: Double,
        balance: Double?,
        costSummaryInlineEnabled: Bool = false) throws -> UsageMenuCardView.Model
    {
        let now = Date(timeIntervalSince1970: 1_773_748_800)
        let metadata = try #require(ProviderDefaults.metadata[.nanogpt])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: used,
                limit: 0,
                currencyCode: "USD",
                period: "Month to date",
                balance: balance,
                updatedAt: now),
            updatedAt: now,
            identity: nil)
        return UsageMenuCardView.Model.make(.init(
            provider: .nanogpt,
            metadata: metadata,
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
            costSummaryInlineEnabled: costSummaryInlineEnabled,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
    }

    @Test
    func `pay as you go card shows month to date spend and the prepaid balance`() throws {
        let model = try self.makeModel(used: 1.5, balance: 12.5)
        let cost = try #require(model.providerCost)
        #expect(cost.title == "Pay-as-you-go")
        #expect(cost.spendLine == "Month to date: $1.50")
        #expect(cost.balanceLine == "Balance: $12.50")
        #expect(cost.percentUsed == nil)
        #expect(cost.percentLine == nil)
    }

    @Test
    func `pay as you go card still shows spend when the balance is missing`() throws {
        let model = try self.makeModel(used: 1.5, balance: nil)
        let cost = try #require(model.providerCost)
        #expect(cost.spendLine == "Month to date: $1.50")
        #expect(cost.balanceLine == nil)
    }

    @Test
    func `subscription meter and prepaid balance show together`() throws {
        let now = Date(timeIntervalSince1970: 1_773_748_800)
        let metadata = try #require(ProviderDefaults.metadata[.nanogpt])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(
                usedPercent: 0,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            providerCost: ProviderCostSnapshot(
                used: 0,
                limit: 0,
                currencyCode: "USD",
                period: "Month to date",
                balance: 12.5,
                updatedAt: now),
            updatedAt: now,
            identity: nil)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .nanogpt,
            metadata: metadata,
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
            costSummaryInlineEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            preferredCurrencyCode: "EUR",
            now: now))
        #expect(model.metrics.contains { $0.id == "secondary" })
        #expect(model.providerCost?.spendLine == "Month to date: $0.00")
        #expect(model.providerCost?.balanceLine == "Balance: $12.50")
    }

    @Test
    func `stored automatic layout shows the prepaid balance beside a token window`() throws {
        let now = Date(timeIntervalSince1970: 1_773_748_800)
        let daily = RateWindow(usedPercent: 0, windowMinutes: 1440, resetsAt: nil, resetDescription: nil)
        let window = try #require(MenuBarLayoutRenderWindow(daily))
        let snapshot = UsageSnapshot(
            primary: daily,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 0,
                limit: 0,
                currencyCode: "USD",
                period: "Month to date",
                balance: 12.5,
                updatedAt: now),
            updatedAt: now,
            identity: nil)
        let text = StatusItemController.menuBarLayoutAutomaticText(
            provider: .nanogpt,
            snapshot: snapshot,
            automatic: window)
        #expect(text == "$12.50")

        let withoutBalance = UsageSnapshot(
            primary: daily,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 0,
                limit: 0,
                currencyCode: "USD",
                period: "Month to date",
                updatedAt: now),
            updatedAt: now,
            identity: nil)
        #expect(StatusItemController.menuBarLayoutAutomaticText(
            provider: .nanogpt,
            snapshot: withoutBalance,
            automatic: window) == nil)
    }
}
