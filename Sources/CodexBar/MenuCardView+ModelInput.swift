import CodexBarCore
import Foundation

extension UsageMenuCardView.Model {
    struct Input {
        let provider: UsageProvider
        let metadata: ProviderMetadata
        let snapshot: UsageSnapshot?
        let codexProjection: CodexConsumerProjection?
        let credits: CreditsSnapshot?
        let creditsError: String?
        let dashboard: OpenAIDashboardSnapshot?
        let dashboardError: String?
        let tokenSnapshot: CostUsageTokenSnapshot?
        let tokenError: String?
        let account: AccountInfo
        let isRefreshing: Bool
        let lastError: String?
        let usageBarsShowUsed: Bool
        let resetTimeDisplayStyle: ResetTimeDisplayStyle
        let tokenCostUsageEnabled: Bool
        let tokenCostInlineDashboardEnabled: Bool
        let tokenCostMenuSectionEnabled: Bool
        let showOptionalCreditsAndExtraUsage: Bool
        let copilotBudgetExtrasEnabled: Bool
        let sourceLabel: String?
        let kiloAutoMode: Bool
        let hidePersonalInfo: Bool
        let weeklyPace: UsagePace?
        let quotaWarningThresholds: [QuotaWarningWindow: [Int]]
        let workDaysPerWeek: Int?
        let usesLiveSubtitle: Bool
        let now: Date

        init(
            provider: UsageProvider,
            metadata: ProviderMetadata,
            snapshot: UsageSnapshot?,
            codexProjection: CodexConsumerProjection? = nil,
            credits: CreditsSnapshot?,
            creditsError: String?,
            dashboard: OpenAIDashboardSnapshot?,
            dashboardError: String?,
            tokenSnapshot: CostUsageTokenSnapshot?,
            tokenError: String?,
            account: AccountInfo,
            isRefreshing: Bool,
            lastError: String?,
            usageBarsShowUsed: Bool,
            resetTimeDisplayStyle: ResetTimeDisplayStyle,
            tokenCostUsageEnabled: Bool,
            tokenCostInlineDashboardEnabled: Bool? = nil,
            tokenCostMenuSectionEnabled: Bool? = nil,
            showOptionalCreditsAndExtraUsage: Bool,
            copilotBudgetExtrasEnabled: Bool = false,
            sourceLabel: String? = nil,
            kiloAutoMode: Bool = false,
            hidePersonalInfo: Bool,
            weeklyPace: UsagePace? = nil,
            quotaWarningThresholds: [QuotaWarningWindow: [Int]] = [:],
            workDaysPerWeek: Int? = nil,
            usesLiveSubtitle: Bool = false,
            now: Date)
        {
            self.provider = provider
            self.metadata = metadata
            self.snapshot = snapshot
            self.codexProjection = codexProjection
            self.credits = credits
            self.creditsError = creditsError
            self.dashboard = dashboard
            self.dashboardError = dashboardError
            self.tokenSnapshot = tokenSnapshot
            self.tokenError = tokenError
            self.account = account
            self.isRefreshing = isRefreshing
            self.lastError = lastError
            self.usageBarsShowUsed = usageBarsShowUsed
            self.resetTimeDisplayStyle = resetTimeDisplayStyle
            self.tokenCostUsageEnabled = tokenCostUsageEnabled
            self.tokenCostInlineDashboardEnabled = tokenCostInlineDashboardEnabled ?? tokenCostUsageEnabled
            self.tokenCostMenuSectionEnabled = tokenCostMenuSectionEnabled ?? tokenCostUsageEnabled
            self.showOptionalCreditsAndExtraUsage = showOptionalCreditsAndExtraUsage
            self.copilotBudgetExtrasEnabled = copilotBudgetExtrasEnabled
            self.sourceLabel = sourceLabel
            self.kiloAutoMode = kiloAutoMode
            self.hidePersonalInfo = hidePersonalInfo
            self.weeklyPace = weeklyPace
            self.quotaWarningThresholds = quotaWarningThresholds
            self.workDaysPerWeek = workDaysPerWeek
            self.usesLiveSubtitle = usesLiveSubtitle
            self.now = now
        }
    }
}
