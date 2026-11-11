import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct NanoGPTMenuCardCostTests {
    private func makeModel(used: Double, balance: Double?) throws -> UsageMenuCardView.Model {
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
            costSummaryInlineEnabled: true,
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
}
