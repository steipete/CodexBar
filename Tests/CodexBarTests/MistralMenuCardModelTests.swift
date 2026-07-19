import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MistralMenuCardModelTests {
    @Test
    func `mistral credit balance renders like deepseek balance`() throws {
        let now = Date()
        let credits = MistralCreditsSnapshot(
            walletAmount: 0,
            creditNotesAmount: 0,
            ongoingUsageBalance: 0,
            currency: "USD")
        let snapshot = MistralUsageSnapshot(
            totalCost: 0,
            currency: "USD",
            currencySymbol: "$",
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalCachedTokens: 0,
            modelCount: 0,
            credits: credits,
            startDate: nil,
            endDate: nil,
            updatedAt: now)
            .toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.mistral])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .mistral,
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
        #expect(primary.title == "Balance")
        #expect(primary.statusText == "$0.00")
        #expect(primary.resetText == nil)
        #expect(primary.detailText == nil)
    }

    @Test
    func `mistral credit balance renders separately from primary percent lane`() throws {
        let now = Date()
        let credits = MistralCreditsSnapshot(
            walletAmount: 10,
            creditNotesAmount: 2.5,
            ongoingUsageBalance: 0,
            currency: "USD")
        let usage = MistralUsageSnapshot(
            totalCost: 0,
            currency: "USD",
            currencySymbol: "$",
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalCachedTokens: 0,
            modelCount: 0,
            credits: credits,
            startDate: nil,
            endDate: nil,
            updatedAt: now)
            .toUsageSnapshot()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 73,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                resetDescription: "API spend this month"),
            secondary: nil,
            tertiary: nil,
            mistralUsage: usage.mistralUsage,
            updatedAt: now,
            identity: usage.identity)
        let metadata = try #require(ProviderDefaults.metadata[.mistral])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .mistral,
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
        #expect(primary.id == "mistral-balance")
        #expect(primary.statusText == "$12.50")
        #expect(primary.detailText == nil)
        #expect(primary.resetText == nil)

        let percentMetric = try #require(model.metrics.dropFirst().first)
        #expect(percentMetric.id == "primary")
        #expect(percentMetric.percent == 27)
        #expect(percentMetric.detailText == "API spend this month")
    }

    @Test
    func `mistral model surfaces monthly cost as primary detail text`() throws {
        let now = Date()
        let resetsAt = now.addingTimeInterval(3 * 24 * 60 * 60)
        let identity = ProviderIdentitySnapshot(
            providerID: .mistral,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: resetsAt,
                resetDescription: "€1.2345 this month"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.mistral])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .mistral,
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
        #expect(primary.detailText == "€1.2345 this month")
        #expect(primary.resetText?.hasPrefix("Resets") == true)
    }
}
