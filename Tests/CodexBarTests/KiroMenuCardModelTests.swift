import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct KiroMenuCardModelTests {
    @Test
    func `kiro model shows account plan credits bonus and overages`() throws {
        let now = Date()
        let snapshot = KiroUsageSnapshot(
            planName: "KIRO FREE",
            accountEmail: "person@example.com",
            authMethod: "Google",
            creditsUsed: 0.17,
            creditsTotal: 50,
            creditsPercent: 0,
            bonusCreditsUsed: 45.53,
            bonusCreditsTotal: 2000,
            bonusExpiryDays: 19,
            overagesStatus: "Enabled billed at $0.04 per request",
            overageCreditsUsed: 40.29,
            estimatedOverageCostUSD: 1.61,
            manageURL: "https://app.kiro.dev/account/usage",
            contextUsage: KiroContextUsageSnapshot(
                totalPercentUsed: 1.3,
                contextFilesPercent: 0.5,
                toolsPercent: 0.8,
                kiroResponsesPercent: 0,
                promptsPercent: 0),
            resetsAt: now.addingTimeInterval(3600),
            updatedAt: now).toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.kiro])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .kiro,
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

        #expect(model.email == "person@example.com")
        #expect(model.planText == "Kiro Free")
        #expect(model.metrics.map(\.title) == ["Credits", "Bonus"])
        #expect(model.metrics.first?.detailLeftText == "49.83 of 50 credits left")
        #expect(model.metrics.dropFirst().first?.detailLeftText == "1954.47 of 2000 bonus credits left")
        #expect(model.usageNotes.contains("Auth: Google"))
        #expect(model.usageNotes.contains("Overages: Enabled billed at $0.04 per request"))
        #expect(model.usageNotes.contains("Overage usage: 40.29 credits"))
        #expect(model.usageNotes.contains("Overage cost: $1.61"))
        #expect(model.usageNotes.contains { $0.localizedCaseInsensitiveContains("Context window") } == false)
    }

    @Test
    func `kiro model hides overage spend when overages are disabled`() throws {
        let now = Date()
        let snapshot = KiroUsageSnapshot(
            planName: "KIRO FREE",
            creditsUsed: 0.17,
            creditsTotal: 50,
            creditsPercent: 0,
            bonusCreditsUsed: nil,
            bonusCreditsTotal: nil,
            bonusExpiryDays: nil,
            overagesStatus: "Disabled",
            overageCreditsUsed: 40.29,
            estimatedOverageCostUSD: 1.61,
            resetsAt: nil,
            updatedAt: now).toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.kiro])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .kiro,
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

        #expect(model.usageNotes.contains("Overages: Disabled"))
        #expect(model.usageNotes.contains("Overage usage: 40.29 credits") == false)
        #expect(model.usageNotes.contains("Overage cost: $1.61") == false)
    }
}
