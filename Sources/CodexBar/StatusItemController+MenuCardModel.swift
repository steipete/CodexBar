import CodexBarCore
import Foundation

extension StatusItemController {
    func menuCardModel(
        for provider: UsageProvider?,
        snapshotOverride: UsageSnapshot? = nil,
        errorOverride: String? = nil,
        forceOverrideCard: Bool = false,
        accountOverride: AccountInfo? = nil) -> UsageMenuCardView.Model?
    {
        let target = provider ?? self.store.enabledProvidersForDisplay().first ?? .codex
        let metadata = self.store.metadata(for: target)

        let usesOverrideCard = forceOverrideCard || snapshotOverride != nil || errorOverride != nil
        let surface: CodexConsumerProjection.Surface = if usesOverrideCard {
            .overrideCard
        } else {
            .liveCard
        }
        // Override cards belong to a specific account/context. Never fall back to
        // provider-level live data here; that can belong to a different account.
        let snapshot: UsageSnapshot? = if surface == .overrideCard {
            snapshotOverride
        } else {
            snapshotOverride ?? self.store.snapshot(for: target)
        }
        let now = Date()
        let codexProjection = self.store.codexConsumerProjectionIfNeeded(
            for: target,
            surface: surface,
            snapshotOverride: snapshotOverride,
            errorOverride: errorOverride,
            now: now)
        let credits: CreditsSnapshot?
        let creditsError: String?
        let dashboard: OpenAIDashboardSnapshot?
        let dashboardError: String?
        let tokenSnapshot: CostUsageTokenSnapshot?
        let tokenError: String?
        if let codexProjection {
            credits = codexProjection.credits?.snapshot
            creditsError = codexProjection.credits?.userFacingError
            dashboard = nil
            dashboardError = codexProjection.userFacingErrors.dashboard
            if surface == .liveCard {
                tokenSnapshot = self.store.tokenSnapshot(for: target)
                tokenError = self.store.tokenError(for: target)
            } else {
                tokenSnapshot = nil
                tokenError = nil
            }
        } else if target == .claude || target == .vertexai, snapshotOverride == nil {
            credits = nil
            creditsError = nil
            dashboard = nil
            dashboardError = nil
            tokenSnapshot = self.store.tokenSnapshot(for: target)
            tokenError = self.store.tokenError(for: target)
        } else {
            credits = nil
            creditsError = nil
            dashboard = nil
            dashboardError = nil
            tokenSnapshot = nil
            tokenError = nil
        }

        let sourceLabel = snapshotOverride == nil ? self.store.sourceLabel(for: target) : nil
        let kiloAutoMode = target == .kilo && self.settings.kiloUsageDataSource == .auto
        // Abacus uses primary for monthly credits (no secondary window)
        let paceWindow = target == .abacus ? snapshot?.primary : snapshot?.secondary
        let weeklyPace = if let codexProjection,
                            let weekly = codexProjection.rateWindow(for: .weekly)
        {
            self.store.weeklyPace(provider: target, window: weekly, now: now)
        } else {
            paceWindow.flatMap { window in
                self.store.weeklyPace(provider: target, window: window, now: now)
            }
        }
        let input = UsageMenuCardView.Model.Input(
            provider: target,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: codexProjection,
            credits: credits,
            creditsError: creditsError,
            dashboard: dashboard,
            dashboardError: dashboardError,
            tokenSnapshot: tokenSnapshot,
            tokenError: tokenError,
            account: accountOverride ?? self.store.accountInfo(for: target),
            isRefreshing: self.store.shouldShowRefreshingMenuCard(for: target),
            lastError: errorOverride
                ?? codexProjection?.userFacingErrors.usage
                ?? self.store.userFacingError(for: target),
            usageBarsShowUsed: self.settings.usageBarsShowUsed,
            resetTimeDisplayStyle: self.settings.resetTimeDisplayStyle,
            tokenCostUsageEnabled: self.settings.isCostUsageEffectivelyEnabled(for: target),
            showOptionalCreditsAndExtraUsage: self.settings.showOptionalCreditsAndExtraUsage,
            sourceLabel: sourceLabel,
            kiloAutoMode: kiloAutoMode,
            hidePersonalInfo: self.settings.hidePersonalInfo,
            claudePeakHoursEnabled: self.settings.claudePeakHoursEnabled,
            weeklyPace: weeklyPace,
            quotaWarningThresholds: [
                .session: self.quotaWarningMarkerThresholds(provider: target, window: .session),
                .weekly: self.quotaWarningMarkerThresholds(provider: target, window: .weekly),
            ],
            now: now)
        return UsageMenuCardView.Model.make(input)
    }

    func accountInfo(for account: CodexVisibleAccount) -> AccountInfo {
        AccountInfo(email: account.email, plan: account.workspaceLabel)
    }

    private func quotaWarningMarkerThresholds(provider: UsageProvider, window: QuotaWarningWindow) -> [Int] {
        guard self.settings.quotaWarningEnabled(provider: provider, window: window) else { return [] }
        return self.settings.resolvedQuotaWarningThresholds(provider: provider, window: window)
    }
}
