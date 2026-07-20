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
        let accountIsAuthoritative: Bool
        let planOverride: String?
        let isRefreshing: Bool
        let lastError: String?
        let limitsAvailability: UsageLimitsAvailability?
        let usageBarsShowUsed: Bool
        let resetTimeDisplayStyle: ResetTimeDisplayStyle
        let tokenCostUsageEnabled: Bool
        let codexLocalSessionCostLedgerEnabled: Bool
        let tokenCostInlineDashboardEnabled: Bool
        let tokenCostMenuSectionEnabled: Bool
        let costComparisonPeriodsEnabled: Bool
        let showOptionalCreditsAndExtraUsage: Bool
        let codexSparkUsageVisible: Bool
        let copilotBudgetExtrasEnabled: Bool
        let sourceLabel: String?
        let kiloAutoMode: Bool
        let hidePersonalInfo: Bool
        let weeklyPace: UsagePace?
        let sessionEquivalentForecast: SessionEquivalentForecast?
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
            accountIsAuthoritative: Bool = false,
            planOverride: String? = nil,
            isRefreshing: Bool,
            lastError: String?,
            limitsAvailability: UsageLimitsAvailability? = nil,
            usageBarsShowUsed: Bool,
            resetTimeDisplayStyle: ResetTimeDisplayStyle,
            tokenCostUsageEnabled: Bool,
            codexLocalSessionCostLedgerEnabled: Bool = false,
            tokenCostInlineDashboardEnabled: Bool? = nil,
            tokenCostMenuSectionEnabled: Bool? = nil,
            costComparisonPeriodsEnabled: Bool = false,
            showOptionalCreditsAndExtraUsage: Bool,
            codexSparkUsageVisible: Bool = true,
            copilotBudgetExtrasEnabled: Bool = false,
            sourceLabel: String? = nil,
            kiloAutoMode: Bool = false,
            hidePersonalInfo: Bool,
            weeklyPace: UsagePace? = nil,
            sessionEquivalentForecast: SessionEquivalentForecast? = nil,
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
            self.accountIsAuthoritative = accountIsAuthoritative
            self.planOverride = planOverride
            self.isRefreshing = isRefreshing
            self.lastError = lastError
            self.limitsAvailability = limitsAvailability
            self.usageBarsShowUsed = usageBarsShowUsed
            self.resetTimeDisplayStyle = resetTimeDisplayStyle
            self.tokenCostUsageEnabled = tokenCostUsageEnabled
            self.codexLocalSessionCostLedgerEnabled = codexLocalSessionCostLedgerEnabled
            self.tokenCostInlineDashboardEnabled = tokenCostInlineDashboardEnabled ?? tokenCostUsageEnabled
            self.tokenCostMenuSectionEnabled = tokenCostMenuSectionEnabled ?? tokenCostUsageEnabled
            self.costComparisonPeriodsEnabled = costComparisonPeriodsEnabled
            self.showOptionalCreditsAndExtraUsage = showOptionalCreditsAndExtraUsage
            self.codexSparkUsageVisible = codexSparkUsageVisible
            self.copilotBudgetExtrasEnabled = copilotBudgetExtrasEnabled
            self.sourceLabel = sourceLabel
            self.kiloAutoMode = kiloAutoMode
            self.hidePersonalInfo = hidePersonalInfo
            self.weeklyPace = weeklyPace
            self.sessionEquivalentForecast = sessionEquivalentForecast
            self.quotaWarningThresholds = quotaWarningThresholds
            self.workDaysPerWeek = workDaysPerWeek
            self.usesLiveSubtitle = usesLiveSubtitle
            self.now = now
        }
    }
}
