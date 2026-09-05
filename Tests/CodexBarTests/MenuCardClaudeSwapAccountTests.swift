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
        planOverride: String? = nil,
        additionalRateWindows: [NamedRateWindow] = []) throws -> UsageMenuCardView.Model
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
                    sevenDay: ClaudeSwapUsageWindow(usedPercent: 60, resetsAt: now.addingTimeInterval(86400)),
                    scoped: [
                        ClaudeSwapScopedUsageWindow(
                            name: "Fable",
                            usedPercent: 80,
                            resetsAt: now.addingTimeInterval(86400)),
                    ]),
            ])
        let account = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: now).first)
        let baseSnapshot = try #require(account.snapshot)
        let snapshot = baseSnapshot.with(
            extraRateWindows: (baseSnapshot.extraRateWindows ?? []) + additionalRateWindows)

        return UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: account.displayLabel, plan: nil),
            accountIsAuthoritative: true,
            planOverride: planOverride,
            isRefreshing: false,
            lastError: account.error,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            sourceLabel: ClaudeSwapAccountProjection.sourceLabel,
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
        let scoped = try #require(model.metrics.first(where: { $0.id == "claude-weekly-scoped-fable" }))
        #expect(scoped.title == "Fable only")
        #expect(scoped.percent == 80)
        #expect(scoped.detailLeftText == "6% in reserve")
        #expect(scoped.pacePercent != nil)
    }

    @Test
    func `claude nonweekly extra window does not render pace detail`() throws {
        let now = Date(timeIntervalSince1970: 1_782_000_000)
        let model = try self.makeModel(
            hidePersonalInfo: false,
            additionalRateWindows: [
                NamedRateWindow(
                    id: "claude-nonweekly-extra",
                    title: "Nonweekly extra",
                    window: RateWindow(
                        usedPercent: 80,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(4 * 60 * 60),
                        resetDescription: nil)),
            ])

        let extra = try #require(model.metrics.first(where: { $0.id == "claude-nonweekly-extra" }))
        #expect(extra.detailLeftText == nil)
        #expect(extra.detailRightText == nil)
        #expect(extra.pacePercent == nil)
    }

    @Test
    func `claude swap account card respects hide personal info`() throws {
        let model = try self.makeModel(hidePersonalInfo: true)

        #expect(!model.email.contains("personal@example.com"))
        #expect(!model.email.contains("example.com"))
    }

    @Test
    func `claude swap cards that share an email include the organization name`() throws {
        let now = Date(timeIntervalSince1970: 1_782_000_000)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "shared@example.com",
                    organizationName: "Sendbird",
                    isActive: true,
                    usageStatus: .ok,
                    fiveHour: ClaudeSwapUsageWindow(usedPercent: 10, resetsAt: now),
                    sevenDay: nil),
                ClaudeSwapAccountRow(
                    number: 2,
                    email: "shared@example.com",
                    organizationName: "Acme",
                    isActive: false,
                    usageStatus: .ok,
                    fiveHour: ClaudeSwapUsageWindow(usedPercent: 20, resetsAt: now),
                    sevenDay: nil),
            ])
        let models = ClaudeSwapAccountProjection.accountSnapshots(from: list, now: now).map { account in
            UsageMenuCardView.Model.make(.init(
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
                accountIsAuthoritative: true,
                isRefreshing: false,
                lastError: account.error,
                usageBarsShowUsed: true,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: false,
                sourceLabel: ClaudeSwapAccountProjection.sourceLabel,
                hidePersonalInfo: false,
                now: now))
        }

        #expect(models.map(\.email) == [
            "shared@example.com · Sendbird",
            "shared@example.com · Acme",
        ])
    }

    @Test
    func `at limit unavailable card keeps usage bars and names the exhausted window`() throws {
        let now = Date(timeIntervalSince1970: 1_782_000_000)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "limited@example.com",
                    isActive: true,
                    usageStatus: .unavailable,
                    fiveHour: ClaudeSwapUsageWindow(usedPercent: 100, resetsAt: now.addingTimeInterval(3600)),
                    sevenDay: ClaudeSwapUsageWindow(usedPercent: 100, resetsAt: now.addingTimeInterval(86400))),
            ])
        let account = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: now).first)
        let snapshot = try #require(account.snapshot)

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
            account: AccountInfo(email: account.displayLabel, plan: nil),
            isRefreshing: false,
            lastError: account.error,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: false,
            now: now))

        #expect(model.email == "limited@example.com")
        let primary = try #require(model.metrics.first(where: { $0.id == "primary" }))
        #expect(primary.percent == 100)
        let secondary = try #require(model.metrics.first(where: { $0.id == "secondary" }))
        #expect(secondary.percent == 100)
        #expect(model.subtitleText ==
            "Session limit reached. Resets in 1h. Weekly limit reached. Resets in 1d.")
        #expect(model.subtitleStyle == .error)
        #expect(!model.subtitleText.contains("Usage fetch failed"))
    }
}
