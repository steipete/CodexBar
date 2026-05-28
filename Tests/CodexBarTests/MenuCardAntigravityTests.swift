import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardAntigravityTests {
    @Test
    func `antigravity metrics show zero percent for missing families`() throws {
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

        #expect(model.metrics.count == 3)
        #expect(model.metrics.map(\.title) == ["Claude", "Gemini Pro", "Gemini Flash"])
        #expect(model.metrics[1].percent == 0)
        #expect(model.metrics[1].percentLabel == "0% left")
        #expect(model.metrics[1].statusText == nil)
        #expect(model.metrics[1].detailText == nil)
        #expect(model.metrics[2].percent == 0)
        #expect(model.metrics[2].percentLabel == "0% left")
        #expect(model.metrics[2].statusText == nil)
        #expect(model.metrics[2].detailText == nil)
    }

    @Test
    func `antigravity zero percent metric still shows reset text`() throws {
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

        #expect(model.metrics[1].percent == 0)
        #expect(model.metrics[1].percentLabel == "0% left")
        #expect(model.metrics[1].resetText != nil)
    }

    @Test
    func `antigravity metrics include complete per model quota windows`() throws {
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

        #expect(model.metrics.map(\.title) == [
            "Claude",
            "Gemini Pro",
            "Gemini Flash",
            "Claude Opus 4.6 (Thinking)",
            "Gemini 3 Pro (High)",
            "Gemini 3 Pro (Low)",
            "GPT-OSS 120B (Medium)",
        ])
        #expect(model.metrics.suffix(4).map(\.percentLabel) == [
            "75% left",
            "100% left",
            "50% left",
            "25% left",
        ])
    }

    @Test
    func `antigravity per model extra windows still render when optional extras are disabled`() throws {
        // Regression: the optional-credits/extra-usage setting is Codex-specific and must NOT hide
        // other providers' core extra windows (here Antigravity per-model quotas).
        let now = Date(timeIntervalSince1970: 1_735_000_000)
        let resetTime = now.addingTimeInterval(3600)
        let antigravitySnapshot = AntigravityStatusSnapshot(
            modelQuotas: [
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

        // Per-model extra windows remain visible even with optional extras disabled.
        #expect(model.metrics.contains { $0.title == "Claude Opus 4.6 (Thinking)" })
        #expect(model.metrics.contains { $0.title == "Gemini 3 Pro (High)" })
    }

    @Test
    func `antigravity missing families show full usage in used mode`() throws {
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

        #expect(model.metrics[1].percent == 100)
        #expect(model.metrics[1].percentLabel == "100% used")
        #expect(model.metrics[2].percent == 100)
        #expect(model.metrics[2].percentLabel == "100% used")
    }
}
