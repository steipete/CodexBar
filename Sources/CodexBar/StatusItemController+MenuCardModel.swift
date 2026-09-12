import CodexBarCore
import Foundation

extension StatusItemController {
    func makeMenuCardRefreshMonitor() -> MenuCardRefreshMonitor {
        MenuCardRefreshMonitor(
            resolveModel: { [weak self] provider in
                self?.menuCardModel(for: provider)
            },
            isProviderRefreshActive: { [weak self] provider in
                self?.store.refreshingProviders.contains(provider.instanceID) == true
            })
    }

    func menuCardModel(
        for provider: UsageProvider?,
        snapshotOverride: UsageSnapshot? = nil,
        errorOverride: String? = nil,
        forceOverrideCard: Bool = false,
        accountOverride: AccountInfo? = nil,
        historySelectionOverride: PlanUtilizationHistorySelection? = nil,
        planOverride: String? = nil,
        subtitleOverride: String? = nil,
        sourceLabelOverride: String? = nil,
        creditsOverride: CreditsSnapshot? = nil) -> UsageMenuCardView.Model?
    {
        // Provider-specific by design: Codex is the historical card fallback when no enabled provider is available.
        let target = provider ?? self.store.enabledFirstPartyProvidersForDisplay().first ?? .codex
        let metadata = self.store.metadata(for: target)

        let usesOverrideCard = forceOverrideCard || snapshotOverride != nil || errorOverride != nil ||
            accountOverride !=
            nil
        let surface: CodexConsumerProjection.Surface = if usesOverrideCard {
            .overrideCard
        } else {
            .liveCard
        }
        // Override cards belong to a specific account/context. Never fall back to
        // provider-level live data here; that can belong to a different account.
        let snapshot = surface == .overrideCard ? snapshotOverride : self.store.presentationSnapshot(for: target)
        let projectedTokenSnapshot = self.store.tokenSnapshot(fromProviderSnapshot: snapshot, provider: target)
        let storedTokenSnapshot = UsageStore.tokenCostRequiresProviderSnapshot(target)
            ? nil
            : self.store.tokenSnapshot(for: target)
        let now = Date()
        let codexProjection = self.store.codexConsumerProjectionIfNeeded(
            for: target,
            surface: surface,
            snapshotOverride: snapshotOverride,
            errorOverride: errorOverride,
            creditsOverride: surface == .overrideCard ? creditsOverride : nil,
            now: now)
        let tokenSnapshot: CostUsageTokenSnapshot?
        let tokenError: String?
        // Account override cards never inherit provider-level token history or errors.
        if surface == .liveCard,
           codexProjection != nil || ProviderDescriptorRegistry.descriptor(for: target).tokenCost.supportsTokenCost
        {
            tokenSnapshot = projectedTokenSnapshot ?? storedTokenSnapshot
            tokenError = self.store.tokenError(for: target)
        } else {
            tokenSnapshot = projectedTokenSnapshot
            tokenError = nil
        }

        let sourceLabel = sourceLabelOverride ?? (surface == .liveCard ? self.store.sourceLabel(for: target) : nil)
        // Provider-specific by design: Kilo's automatic source mode is surfaced as card fallback context.
        let kiloAutoMode = target == .kilo && self.settings.kiloUsageDataSource == .auto
        let (weeklyPace, sessionEquivalentForecast) = self.resolvePaceAndForecast(
            target: target,
            snapshot: snapshot,
            codexProjection: codexProjection,
            usesOverrideCard: surface == .overrideCard,
            historySelectionOverride: historySelectionOverride,
            now: now)
        let fallbackAccount = accountOverride
            ?? (metadata.usesAccountFallback
                ? self.store.accountInfo(for: target)
                : AccountInfo(email: nil, plan: nil))
        let input = UsageMenuCardView.Model.Input(
            provider: target,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: codexProjection,
            credits: codexProjection?.credits?.snapshot,
            // Optional dashboard setup diagnostics belong in provider Settings.
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: tokenError,
            account: fallbackAccount,
            accountIsAuthoritative: accountOverride != nil,
            planOverride: planOverride,
            isRefreshing: self.store.shouldShowRefreshingMenuCardIndicator(for: target),
            // Provider-level errors can belong to a different account, so
            // override cards never inherit them (same rule as the snapshot,
            // token-cost, and source-label fallbacks above).
            lastError: errorOverride
                ?? codexProjection?.userFacingErrors.usage
                ?? (surface == .liveCard ? self.store.userFacingError(for: target) : nil),
            limitsAvailability: self.store.knownLimitsAvailability(for: target),
            usageBarsShowUsed: self.settings.usageBarsShowUsed,
            resetTimeDisplayStyle: self.settings.resetTimeDisplayStyle,
            tokenCostUsageEnabled: self.settings.isCostUsageEffectivelyEnabled(for: target),
            tokenCostIsRefreshing: self.store.tokenCostRefreshIsActive(for: target),
            codexLocalSessionCostLedgerEnabled: self.settings.codexLocalSessionCostLedgerEnabled,
            costSummaryInlineEnabled: self.settings.costSummaryShowsInline(for: target),
            // openai/mistral's cost history always surfaces via the inline dashboard or a
            // dedicated top-pane submenu (see `makeUsageSubmenu`), so they skip the generic
            // "Cost" row. This must stay an explicit provider check rather than reusing
            // `usesProviderCostHistoryAsPrimaryDashboard` (or `tokenCostRequiresProviderSnapshot`):
            // both of those sets are shared with unrelated concerns (inline-dashboard eligibility,
            // provider-derived snapshot sourcing) and gain members for reasons that have nothing to
            // do with whether this row should show, silently disabling the Cost row for those
            // providers too (e.g. groq's addition to the inline-dashboard set previously did this).
            tokenCostMenuSectionEnabled: ProviderDescriptorRegistry.descriptor(for: target).tokenCost
                .showsCostMenuSection &&
                self.settings.costSummaryShowsSubmenu(for: target),
            costComparisonPeriodsEnabled: self.settings.costComparisonPeriodsEnabled,
            showOptionalCreditsAndExtraUsage: self.settings.showOptionalCreditsAndExtraUsage,
            claudeDailyRoutinesUsageVisible: true,
            codexSparkUsageVisible: true,
            copilotBudgetExtrasEnabled: self.settings.copilotBudgetExtrasEnabled,
            sourceLabel: sourceLabel,
            subtitleOverride: subtitleOverride,
            kiloAutoMode: kiloAutoMode,
            hidePersonalInfo: self.settings.hidePersonalInfo,
            weeklyPace: weeklyPace,
            sessionEquivalentForecast: sessionEquivalentForecast,
            quotaWarningThresholds: [
                .session: self.quotaWarningMarkerThresholds(provider: target, window: .session),
                .weekly: self.quotaWarningMarkerThresholds(provider: target, window: .weekly),
            ],
            workDaysPerWeek: self.settings.weeklyProgressWorkDays,
            workdayTickAppearance: self.settings.workdayTickAppearance,
            paceVisible: self.settings.paceVisible,
            usesLiveSubtitle: surface == .liveCard,
            preferredCurrencyCode: self.settings.preferredCurrencyCode,
            costUsageBucketCalendar: self.settings.costUsageBucketCalendar,
            now: now)
        return UsageMenuCardView.Model.make(input).applyingUsageItemVisibility(
            hiddenItemIDs: self.settings.hiddenUsageItemIDs(for: target))
    }

    // swiftlint:disable:next function_parameter_count
    private func resolvePaceAndForecast(
        target: UsageProvider,
        snapshot: UsageSnapshot?,
        codexProjection: CodexConsumerProjection?,
        usesOverrideCard: Bool,
        historySelectionOverride: PlanUtilizationHistorySelection?,
        now: Date)
        -> (weeklyPace: UsagePace?, sessionEquivalentForecast: SessionEquivalentForecast?)
    {
        let paceWindow = snapshot.flatMap {
            ProviderDescriptorRegistry.descriptor(for: target).presentation.semanticWindows(snapshot: $0).weekly
        }
        let historySelection = self.sessionEquivalentHistorySelection(
            provider: target,
            snapshot: snapshot,
            usesOverrideCard: usesOverrideCard,
            override: historySelectionOverride)
        let weeklyPace = if let codexProjection,
                            let weekly = codexProjection.rateWindow(for: .weekly)
        {
            self.store.weeklyPace(
                provider: target,
                window: weekly,
                dataConfidence: snapshot?.dataConfidence ?? .unknown,
                now: now)
        } else {
            paceWindow.flatMap { window in
                self.store.weeklyPace(
                    provider: target,
                    window: window,
                    dataConfidence: snapshot?.dataConfidence ?? .unknown,
                    now: now)
            }
        }
        let forecast: SessionEquivalentForecast? = if let codexProjection,
                                                      let session = codexProjection
                                                          .rateWindow(for: .session),
                                                          let weekly = codexProjection
                                                              .rateWindow(for: .weekly)
        {
            self.store.sessionEquivalentForecast(
                provider: target,
                sessionWindow: session,
                weeklyWindow: weekly,
                historySelection: historySelection,
                now: now)
        } else if let snapshot,
                  let windows = self.store.sessionEquivalentWindows(
                      provider: target, snapshot: snapshot)
        {
            self.store.sessionEquivalentForecast(
                provider: target,
                sessionWindow: windows.session,
                weeklyWindow: windows.weekly,
                weeklyWindowID: windows.weeklyWindowID,
                historyIdentity: windows.historyIdentity,
                historySelection: historySelection,
                now: now)
        } else {
            nil
        }
        return (weeklyPace, forecast)
    }

    private func sessionEquivalentHistorySelection(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        usesOverrideCard: Bool,
        override: PlanUtilizationHistorySelection?) -> PlanUtilizationHistorySelection?
    {
        guard usesOverrideCard else { return nil }
        if let override {
            return override
        }
        guard let snapshot else { return .unavailable }
        return self.store.planUtilizationHistorySelection(for: provider, snapshotOverride: snapshot)
    }

    func accountInfo(for account: CodexVisibleAccount) -> AccountInfo {
        AccountInfo(email: account.email, plan: account.workspaceLabel)
    }

    private func quotaWarningMarkerThresholds(provider: UsageProvider, window: QuotaWarningWindow) -> [Int] {
        guard self.settings.quotaWarningMarkersVisible else { return [] }
        guard self.settings.quotaWarningEnabled(provider: provider, window: window) else { return [] }
        return self.settings.resolvedQuotaWarningThresholds(provider: provider, window: window)
    }
}
