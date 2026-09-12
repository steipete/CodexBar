import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardModelCodexBusinessCreditsTests {
    @Test(arguments: [false, true])
    func `workspace balance omits the invented token progress scale`(balanceIsWorkspace: Bool) throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let credits = CreditsSnapshot(
            remaining: 1234,
            events: [],
            updatedAt: now,
            creditsAvailable: true,
            balanceIsWorkspace: balanceIsWorkspace)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: nil,
            credits: credits,
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

        #expect(model.creditsRemaining == 1234)
        #expect(model.creditsShowProgress == !balanceIsWorkspace)
        var changedProgress = model
        changedProgress.creditsShowProgress.toggle()
        #expect(!model.hasCompatibleTrackedLayout(with: changedProgress))
        #expect(model.heightFingerprint(section: "credits") != changedProgress.heightFingerprint(section: "credits"))
    }

    @Test
    func `codex workspace hidden balance never renders as zero credits`() throws {
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let credits = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: Date(),
            balanceReadSucceeded: false,
            creditsAvailable: true)

        let line = UsageMenuCardView.Model.creditsLine(
            metadata: metadata,
            snapshot: nil,
            credits: credits,
            error: nil)

        #expect(line == "Credits · Balance: Unavailable")
        #expect(credits.displayRemaining == nil)
        #expect(UsageMenuCardView.Model.creditsProgressPercent(credits: credits) == nil)
    }

    @Test
    func `ordinary credit availability preserves the individual monthly limit display`() throws {
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let now = Date()
        let credits = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 100,
                limit: 1000,
                remainingPercent: 90,
                resetsAt: nil,
                updatedAt: now),
            balanceReadSucceeded: true,
            creditsAvailable: true)

        #expect(UsageMenuCardView.Model.creditsLine(
            metadata: metadata,
            snapshot: nil,
            credits: credits,
            error: nil) == "900 left")
        #expect(credits.displayRemaining == 900)
        #expect(UsageMenuCardView.Model.creditsProgressPercent(credits: credits) == 90)
        #expect(UsageMenuCardView.Model.creditsScaleText(credits: credits) == "of 1000")
    }

    @Test
    func `codex owner visible workspace balance wins over exhausted individual limit`() throws {
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let now = Date()
        let credits = CreditsSnapshot(
            remaining: 1234,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 1000,
                limit: 1000,
                remainingPercent: 0,
                resetsAt: nil,
                updatedAt: now),
            balanceReadSucceeded: true,
            creditsAvailable: true,
            balanceIsWorkspace: true)

        let line = UsageMenuCardView.Model.creditsLine(
            metadata: metadata,
            snapshot: nil,
            credits: credits,
            error: nil)

        #expect(line == "1234 left")
        #expect(credits.displayRemaining == 1234)
        #expect(UsageMenuCardView.Model.creditsProgressPercent(credits: credits) == nil)
        #expect(UsageMenuCardView.Model.creditsScaleText(credits: credits) == nil)
        #expect(UsageMenuCardView.Model.codexCreditLimitDetail(credits: credits, now: now) == nil)
    }

    @Test
    func `codex business override card shows monthly credit instead of limits unavailable`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "biz@example.com",
            accountOrganization: "Team",
            loginMethod: "business")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: identity)
        let credits = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 27,
                limit: 1000,
                remainingPercent: 73,
                resetsAt: nil,
                updatedAt: now))
        let projection = CodexConsumerProjection.make(
            surface: .overrideCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: credits,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: now))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: projection,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "biz@example.com", plan: "business"),
            isRefreshing: false,
            lastError: UsageError.noRateLimitsFound.errorDescription,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let monthly = try #require(model.metrics.first { $0.id == "monthly" })
        let extraUsage = try #require(model.providerCost)
        #expect(model.placeholder == nil)
        #expect(monthly.title == "Monthly credit limit")
        #expect(monthly.percent == 27)
        #expect(monthly.detailText == "27 / 1000")
        #expect(model.metrics.count == 1)
        #expect(model.subtitleStyle != .error)
        #expect(extraUsage.title == "Extra usage")
        #expect(extraUsage.spendLine == "Monthly credit limit: 27 / 1000")
        #expect(extraUsage.percentLine == "3% used")
        #expect(extraUsage.percentUsed == 2.7)
    }

    @Test
    func `codex business override card hides monthly credit when optional credits are off`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "biz@example.com",
            accountOrganization: "Team",
            loginMethod: "business")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: identity)
        let credits = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 27,
                limit: 1000,
                remainingPercent: 73,
                resetsAt: nil,
                updatedAt: now))
        let projection = CodexConsumerProjection.make(
            surface: .overrideCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: credits,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: now))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: projection,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "biz@example.com", plan: "business"),
            isRefreshing: false,
            lastError: UsageError.noRateLimitsFound.errorDescription,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.contains { $0.id == "monthly" } == false)
        #expect(model.metrics.isEmpty)
        #expect(model.placeholder == "Limits not available")
        #expect(model.providerCost == nil)
    }

    @Test
    func `codex live card shows extra credit used versus limit`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: now)
        let credits = CreditsSnapshot(
            remaining: 50,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 120,
                limit: 400,
                remainingPercent: 70,
                resetsAt: nil,
                updatedAt: now))
        let projection = CodexConsumerProjection.make(
            surface: .liveCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: credits,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: now))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: projection,
            credits: credits,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "member@example.com", plan: "plus"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let extraUsage = try #require(model.providerCost)
        #expect(extraUsage.title == "Extra usage")
        #expect(extraUsage.spendLine == "Monthly credit limit: 120 / 400")
        #expect(extraUsage.percentLine == "30% used")
        #expect(extraUsage.balanceLine == "Balance: 50")
        #expect(model.metrics.contains { $0.id == "monthly" } == false)
    }

    @Test
    func `codex purchased extra credits show remaining balance`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 80, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        let credits = CreditsSnapshot(remaining: 14.5, events: [], updatedAt: now)
        let projection = CodexConsumerProjection.make(
            surface: .overrideCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: credits,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: now))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: projection,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "member@example.com", plan: "pro"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let extraUsage = try #require(model.providerCost)
        #expect(extraUsage.title == "Extra usage")
        #expect(extraUsage.spendLine == "Balance: 14.5")
        #expect(extraUsage.percentUsed == nil)
        #expect(extraUsage.balanceLine == nil)
    }
}
