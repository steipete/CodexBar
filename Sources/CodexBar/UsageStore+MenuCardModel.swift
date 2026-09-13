import CodexBarCore
import Foundation

enum UsageMenuCardContext {
    case menu
    case settings
    case account(Account)

    struct Account {
        var snapshot: UsageSnapshot?
        var error: String?
        var info: AccountInfo?
        var historySelection: PlanUtilizationHistorySelection?
        var plan: String?
        var subtitle: String?
        var sourceLabel: String?
        var credits: CreditsSnapshot?
    }

    var account: Account? {
        guard case let .account(account) = self else { return nil }
        return account
    }

    var isSettings: Bool {
        if case .settings = self { return true }
        return false
    }
}

extension UsageStore {
    func menuCardModel(
        for provider: UsageProvider,
        context: UsageMenuCardContext = .menu,
        now: Date = Date()) -> UsageMenuCardView.Model
    {
        UsageMenuCardView.Model.make(self.menuCardInput(for: provider, context: context, now: now))
            .applyingUsageItemVisibility(hiddenItemIDs: self.settings.hiddenUsageItemIDs(for: provider))
    }

    func menuCardInput(
        for provider: UsageProvider,
        context: UsageMenuCardContext,
        now: Date = Date()) -> UsageMenuCardView.Model.Input
    {
        let account = context.account
        let isSettings = context.isSettings
        let isLive = account == nil
        let metadata = self.metadata(for: provider)
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        // An explicitly empty account stays empty; live data may belong to another account.
        let snapshot = isLive ? self.presentationSnapshot(for: provider) : account?.snapshot
        let codexProjection = self.codexConsumerProjectionIfNeeded(
            for: provider,
            surface: isLive ? .liveCard : .overrideCard,
            snapshotOverride: account?.snapshot,
            errorOverride: account?.error,
            creditsOverride: account?.credits,
            now: now)
        let supportsTokenCost = codexProjection != nil || descriptor.tokenCost.supportsTokenCost
        let tokenSnapshot: CostUsageTokenSnapshot?
        if isSettings {
            tokenSnapshot = supportsTokenCost ? self.tokenSnapshot(for: provider) : nil
        } else {
            let projected = isLive || snapshot != nil
                ? self.tokenSnapshot(fromProviderSnapshot: snapshot, provider: provider)
                : nil
            let stored = isLive && supportsTokenCost && !Self.tokenCostRequiresProviderSnapshot(provider)
                ? self.tokenSnapshot(for: provider)
                : nil
            tokenSnapshot = projected ?? stored
        }
        let weeklyWindow = codexProjection?.rateWindow(for: .weekly)
            ?? snapshot.flatMap { descriptor.presentation.semanticWindows(snapshot: $0).weekly }
        let weeklyPace = weeklyWindow.flatMap {
            self.weeklyPace(
                provider: provider,
                window: $0,
                dataConfidence: snapshot?.dataConfidence ?? .unknown,
                now: now)
        }
        let forecast = isSettings ? nil : self.menuCardSessionEquivalentForecast(
            provider: provider,
            snapshot: snapshot,
            codexProjection: codexProjection,
            account: account,
            now: now)
        return UsageMenuCardView.Model.Input(
            provider: provider,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: codexProjection,
            credits: codexProjection?.credits?.snapshot,
            creditsError: isSettings ? codexProjection?.credits?.userFacingError : nil,
            dashboard: nil,
            dashboardError: isSettings ? codexProjection?.userFacingErrors.dashboard : nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: isLive && supportsTokenCost ? self.tokenError(for: provider) : nil,
            account: account?.info ?? (isLive && metadata.usesAccountFallback
                ? self.accountInfo(for: provider)
                : AccountInfo(email: nil, plan: nil)),
            accountIsAuthoritative: account?.info != nil,
            planOverride: account?.plan,
            isRefreshing: isSettings ? self.refreshingProviders.contains(provider.instanceID)
                : self.shouldShowRefreshingMenuCardIndicator(for: provider),
            lastError: account?.error ?? codexProjection?.userFacingErrors.usage
                ?? (isLive ? self.userFacingError(for: provider) : nil),
            limitsAvailability: self.knownLimitsAvailability(for: provider),
            usageBarsShowUsed: self.settings.usageBarsShowUsed,
            resetTimeDisplayStyle: self.settings.resetTimeDisplayStyle,
            tokenCostUsageEnabled: self.settings.isCostUsageEffectivelyEnabled(for: provider),
            tokenCostIsRefreshing: !isSettings && self.tokenCostRefreshIsActive(for: provider),
            codexLocalSessionCostLedgerEnabled: self.settings.codexLocalSessionCostLedgerEnabled,
            // Settings exposes available costs regardless of the menu's display style.
            costSummaryInlineEnabled: isSettings || self.settings.costSummaryShowsInline(for: provider),
            tokenCostMenuSectionEnabled: isSettings
                ? self.settings.isCostUsageEffectivelyEnabled(for: provider)
                : descriptor.tokenCost.showsCostMenuSection && self.settings.costSummaryShowsSubmenu(for: provider),
            costComparisonPeriodsEnabled: !isSettings && self.settings.costComparisonPeriodsEnabled,
            showOptionalCreditsAndExtraUsage: self.settings.showOptionalCreditsAndExtraUsage,
            copilotBudgetExtrasEnabled: self.settings.copilotBudgetExtrasEnabled,
            showsAllUsageLanes: isSettings,
            sourceLabel: account?.sourceLabel ?? (!isSettings && isLive ? self.sourceLabel(for: provider) : nil),
            subtitleOverride: account?.subtitle,
            // Provider-specific by design: Kilo's menu explains its automatic source fallback.
            kiloAutoMode: !isSettings && provider == .kilo && self.settings.kiloUsageDataSource == .auto,
            hidePersonalInfo: self.settings.hidePersonalInfo,
            weeklyPace: weeklyPace,
            sessionEquivalentForecast: forecast,
            quotaWarningThresholds: [
                .session: self.quotaWarningMarkerThresholds(provider: provider, window: .session),
                .weekly: self.quotaWarningMarkerThresholds(provider: provider, window: .weekly),
            ],
            workDaysPerWeek: self.settings.weeklyProgressWorkDays,
            workdayTickAppearance: self.settings.workdayTickAppearance,
            paceVisible: self.settings.paceVisible,
            usesLiveSubtitle: !isSettings && isLive,
            preferredCurrencyCode: isSettings ? "auto" : self.settings.preferredCurrencyCode,
            costUsageBucketCalendar: self.settings.costUsageBucketCalendar,
            now: now)
    }

    private func menuCardSessionEquivalentForecast(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        codexProjection: CodexConsumerProjection?,
        account: UsageMenuCardContext.Account?,
        now: Date) -> SessionEquivalentForecast?
    {
        let historySelection = account.map { account in
            account.historySelection ?? snapshot.map {
                self.planUtilizationHistorySelection(for: provider, snapshotOverride: $0)
            } ?? .unavailable
        }
        if let session = codexProjection?.rateWindow(for: .session),
           let weekly = codexProjection?.rateWindow(for: .weekly)
        {
            return self.sessionEquivalentForecast(
                provider: provider,
                sessionWindow: session,
                weeklyWindow: weekly,
                historySelection: historySelection,
                now: now)
        }
        guard let snapshot,
              let windows = self.sessionEquivalentWindows(provider: provider, snapshot: snapshot)
        else { return nil }
        return self.sessionEquivalentForecast(
            provider: provider,
            sessionWindow: windows.session,
            weeklyWindow: windows.weekly,
            weeklyWindowID: windows.weeklyWindowID,
            historyIdentity: windows.historyIdentity,
            historySelection: historySelection,
            now: now)
    }

    private func quotaWarningMarkerThresholds(provider: UsageProvider, window: QuotaWarningWindow) -> [Int] {
        guard self.settings.quotaWarningMarkersVisible,
              self.settings.quotaWarningEnabled(provider: provider, window: window)
        else { return [] }
        return self.settings.resolvedQuotaWarningThresholds(provider: provider, window: window)
    }
}
