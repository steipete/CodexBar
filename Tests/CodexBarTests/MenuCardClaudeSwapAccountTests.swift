import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Menu-model coverage for claude-swap account cards: the provider-neutral
/// projection renders as a regular Claude usage card with session/weekly
/// windows, account identity, and Hide Personal Info redaction.
struct MenuCardClaudeSwapAccountTests {
    private func makeModel(
        hidePersonalInfo: Bool,
        planOverride: String? = nil) throws -> UsageMenuCardView.Model
    {
        let now = Date(timeIntervalSince1970: 1_782_000_000)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 2,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 2,
                    email: "personal@example.com",
                    isActive: true,
                    usageStatus: .ok,
                    fiveHour: ClaudeSwapUsageWindow(usedPercent: 25, resetsAt: now.addingTimeInterval(3600)),
                    sevenDay: ClaudeSwapUsageWindow(usedPercent: 60, resetsAt: now.addingTimeInterval(86400))),
            ])
        let account = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: now).first)

        return UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: account.snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: account.displayLabel, plan: nil),
            planOverride: planOverride,
            isRefreshing: false,
            lastError: account.error,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: hidePersonalInfo,
            now: now))
    }

    @Test
    func `claude swap action overrides adapter login method`() throws {
        let model = try self.makeModel(hidePersonalInfo: false, planOverride: "Switch Account...")

        #expect(model.planText == "Switch Account...")
    }

    @Test
    func `claude swap account snapshot renders session and weekly metrics with identity`() throws {
        let model = try self.makeModel(hidePersonalInfo: false)

        #expect(model.email == "personal@example.com")
        let primary = try #require(model.metrics.first(where: { $0.id == "primary" }))
        #expect(primary.percent == 25)
        let secondary = try #require(model.metrics.first(where: { $0.id == "secondary" }))
        #expect(secondary.percent == 60)
    }

    @Test
    func `claude swap account card respects hide personal info`() throws {
        let model = try self.makeModel(hidePersonalInfo: true)

        #expect(!model.email.contains("personal@example.com"))
        #expect(!model.email.contains("example.com"))
    }
}
