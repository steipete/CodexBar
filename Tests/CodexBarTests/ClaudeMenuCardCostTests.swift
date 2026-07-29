import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ClaudeMenuCardCostTests {
    @Test
    func `claude extra usage card shows balance above monthly cap`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            providerCost: ProviderCostSnapshot(
                used: 5,
                limit: 20,
                currencyCode: "USD",
                period: "Monthly cap",
                balance: 100,
                updatedAt: now),
            updatedAt: now,
            identity: nil)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
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

        #expect(model.providerCost?.title == "Extra usage")
        #expect(model.providerCost?.balanceLine == "Balance: $100.00")
        #expect(model.providerCost?.spendLine == "Monthly cap: $5.00 / $20.00")
        #expect(model.providerCost?.percentUsed == 25)
        #expect(model.providerCost?.percentLine == "25% used")
        #expect(model.providerCost?.presentation == .detail)
        #expect(model.providerCost?.showsInProviderDetails == false)
    }

    @Test
    func `claude balance only card stays compact`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 0,
                limit: 0,
                currencyCode: "USD",
                period: "Usage credits",
                balance: 100,
                updatedAt: now),
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
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

        #expect(model.providerCost?.title == "Credits")
        #expect(model.providerCost?.spendLine == "$100.00")
        #expect(model.providerCost?.balanceLine == nil)
        #expect(model.providerCost?.percentUsed == nil)
        #expect(model.providerCost?.percentLine == nil)
        #expect(model.providerCost?.presentation == .inlineValue)
        #expect(model.providerCost?.showsInProviderDetails == false)
    }

    @Test
    func `claude admin api spend remains visible without prepaid balance`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 12.34,
                limit: 0,
                currencyCode: "USD",
                period: "Last 30 days",
                updatedAt: now),
            claudeAdminAPIUsage: ClaudeAdminAPIUsageSnapshot(daily: [], updatedAt: now),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "admin@example.com",
                accountOrganization: nil,
                loginMethod: "Admin API"))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
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
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: false,
            now: now))

        #expect(model.providerCost?.title == "API spend")
        #expect(model.providerCost?.spendLine == "Last 30 days: $12.34")
        #expect(model.providerCost?.presentation == .detail)
        #expect(model.providerCost?.showsInProviderDetails == true)
    }

    @Test
    func `claude monthly cap stays visible when prepaid balance is unavailable`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 0.49,
                limit: 50,
                currencyCode: "USD",
                period: "Monthly cap",
                updatedAt: now),
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
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

        #expect(model.providerCost?.title == "Extra usage")
        #expect(model.providerCost?.balanceLine == nil)
        #expect(model.providerCost?.spendLine == "Monthly cap: $0.49 / $50.00")
        let percentUsed = try #require(model.providerCost?.percentUsed)
        #expect(abs(percentUsed - 0.98) < 0.0001)
        #expect(model.providerCost?.percentLine == "1% used")
        #expect(model.providerCost?.presentation == .detail)
        #expect(model.providerCost?.showsInProviderDetails == false)
    }
}
