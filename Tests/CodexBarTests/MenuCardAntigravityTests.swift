import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardAntigravityTests {
    @Test
    func `antigravity metrics omit missing groups`() throws {
        let now = Date()
        let identity = ProviderIdentitySnapshot(
            providerID: .antigravity,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Pro")
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 5,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.antigravity])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .antigravity,
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

        #expect(model.metrics.count == 1)
        #expect(model.metrics.map(\.title) == ["Gemini Models"])
        #expect(model.metrics[0].percent == 95)
        #expect(model.metrics[0].percentLabel == "95% left")
    }

    @Test
    func `antigravity untracked known row does not duplicate grouped summary`() throws {
        let now = Date(timeIntervalSince1970: 1_735_000_000)
        let resetTime = now.addingTimeInterval(3600)
        let antigravitySnapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Claude Thinking",
                    modelId: "MODEL_PLACEHOLDER_M35",
                    remainingFraction: 0.4,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3.1 Pro (Low)",
                    modelId: "MODEL_PLACEHOLDER_M36",
                    remainingFraction: nil,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "MODEL_PLACEHOLDER_M47",
                    remainingFraction: 1,
                    resetTime: resetTime,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: "Pro")
        let snapshot = try antigravitySnapshot.toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.antigravity])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .antigravity,
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

        #expect(model.metrics.map(\.title) == ["Gemini Models", "Claude and GPT"])
        #expect(!model.metrics.contains { $0.title == "Gemini 3.1 Pro (Low)" })
    }

    @Test
    func `antigravity metrics collapse complete per model quota windows`() throws {
        let now = Date(timeIntervalSince1970: 1_735_000_000)
        let resetTime = now.addingTimeInterval(3600)
        let antigravitySnapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "GPT-OSS 120B (Medium)",
                    modelId: "MODEL_PLACEHOLDER_M55",
                    remainingFraction: 0.25,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (Low)",
                    modelId: "MODEL_PLACEHOLDER_M53",
                    remainingFraction: 0.5,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Claude Opus 4.6 (Thinking)",
                    modelId: "MODEL_PLACEHOLDER_M50",
                    remainingFraction: 0.75,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (High)",
                    modelId: "MODEL_PLACEHOLDER_M52",
                    remainingFraction: 1,
                    resetTime: resetTime,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: "Pro",
            source: .local)
        let snapshot = try antigravitySnapshot.toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.antigravity])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .antigravity,
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

        #expect(model.metrics.map(\.title) == [
            "Gemini Models",
            "Claude and GPT",
        ])
        #expect(model.metrics.map(\.percentLabel) == [
            "50% left",
            "25% left",
        ])
    }

    @Test
    func `antigravity distinct extra windows still render when optional extras are disabled`() throws {
        // Regression: the optional-credits/extra-usage setting is Codex-specific and must NOT hide
        // other providers' core extra windows.
        let now = Date(timeIntervalSince1970: 1_735_000_000)
        let resetTime = now.addingTimeInterval(3600)
        let antigravitySnapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Experimental Tool",
                    modelId: "MODEL_PLACEHOLDER_UNKNOWN",
                    remainingFraction: 0.5,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (High)",
                    modelId: "MODEL_PLACEHOLDER_M52",
                    remainingFraction: 1,
                    resetTime: resetTime,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: "Pro")
        let snapshot = try antigravitySnapshot.toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.antigravity])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .antigravity,
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

        // Distinct extra windows remain visible even with optional extras disabled.
        #expect(model.metrics.contains { $0.title == "Experimental Tool" })
        #expect(model.metrics.contains { $0.title == "Gemini Models" })
    }

    @Test
    func `antigravity quota summary renders named session and weekly rows`() throws {
        let now = Date(timeIntervalSince1970: 1_735_000_000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 27,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: "You have used some of your 5-hour limit, it will fully refresh in 3 hours."),
            secondary: RateWindow(
                usedPercent: 18,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: "You have used some of your weekly limit, it will fully refresh in 5 days."),
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini Models Five Hour Limit",
                    window: RateWindow(
                        usedPercent: 9,
                        windowMinutes: 300,
                        resetsAt: nil,
                        resetDescription: "You have used some of your 5-hour limit, it will fully refresh in "
                            + "4 hours.")),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini Models Weekly Limit",
                    window: RateWindow(
                        usedPercent: 18,
                        windowMinutes: 10080,
                        resetsAt: nil,
                        resetDescription: "You have used some of your weekly limit, it will fully refresh in 5 days.")),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude and GPT models Five Hour Limit",
                    window: RateWindow(
                        usedPercent: 27,
                        windowMinutes: 300,
                        resetsAt: nil,
                        resetDescription: "You have used some of your 5-hour limit, it will fully refresh in "
                            + "3 hours.")),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude and GPT models Weekly Limit",
                    window: RateWindow(
                        usedPercent: 36,
                        windowMinutes: 10080,
                        resetsAt: nil,
                        resetDescription: "You have used some of your weekly limit, it will fully refresh in 6 days.")),
            ],
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Pro"))
        let metadata = try #require(ProviderDefaults.metadata[.antigravity])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .antigravity,
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

        #expect(model.metrics.map(\.id) == [
            "antigravity-quota-summary-gemini-5h",
            "antigravity-quota-summary-gemini-weekly",
            "antigravity-quota-summary-3p-5h",
            "antigravity-quota-summary-3p-weekly",
        ])
        #expect(model.metrics.map(\.title) == [
            "Gemini Models Five Hour Limit",
            "Gemini Models Weekly Limit",
            "Claude and GPT models Five Hour Limit",
            "Claude and GPT models Weekly Limit",
        ])
        #expect(model.metrics.map(\.percentLabel) == [
            "91% left",
            "82% left",
            "73% left",
            "64% left",
        ])
        #expect(model.metrics[2].resetText == "Resets in 3 hours")
    }

    @Test
    func `antigravity missing groups are omitted in used mode`() throws {
        let now = Date()
        let identity = ProviderIdentitySnapshot(
            providerID: .antigravity,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Pro")
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 5,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.antigravity])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .antigravity,
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

        #expect(model.metrics.count == 1)
        #expect(model.metrics[0].title == "Gemini Models")
        #expect(model.metrics[0].percent == 5)
        #expect(model.metrics[0].percentLabel == "5% used")
    }
}
