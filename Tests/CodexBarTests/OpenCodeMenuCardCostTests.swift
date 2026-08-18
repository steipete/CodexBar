import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct OpenCodeMenuCardCostTests {
    private func makeModel(_ usage: OpenCodeUsageSnapshot.PayAsYouGoUsage, now: Date) throws
        -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[.opencode])
        let snapshot = OpenCodeUsageSnapshot.payAsYouGo(usage, updatedAt: now).toUsageSnapshot()
        return UsageMenuCardView.Model.make(.init(
            provider: .opencode,
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
            costSummaryInlineEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
    }

    @Test
    func `pay as you go card shows monthly spend against the limit`() throws {
        let now = Date()
        let model = try self.makeModel(
            .init(monthlyUsageUSD: 15, monthlyLimitUSD: 20, balanceUSD: 12.5),
            now: now)

        #expect(model.providerCost?.spendLine == "Monthly: $15.00 / $20.00")
        #expect(model.providerCost?.percentUsed == 75)
    }

    @Test
    func `pay as you go card without a limit still shows spend and balance`() throws {
        let now = Date()
        let model = try self.makeModel(
            .init(monthlyUsageUSD: 15, monthlyLimitUSD: nil, balanceUSD: 12.5),
            now: now)

        let cost = try #require(model.providerCost)
        #expect(cost.title == "Pay-as-you-go")
        #expect(cost.spendLine == "Monthly: $15.00")
        #expect(cost.balanceLine == "Balance: $12.50")
        #expect(cost.percentUsed == nil)
        #expect(cost.percentLine == nil)
    }

    @Test
    func `pay as you go card without a limit or balance still shows spend`() throws {
        let now = Date()
        let model = try self.makeModel(
            .init(monthlyUsageUSD: 15, monthlyLimitUSD: nil, balanceUSD: nil),
            now: now)

        let cost = try #require(model.providerCost)
        #expect(cost.spendLine == "Monthly: $15.00")
        #expect(cost.balanceLine == nil)
    }
}
