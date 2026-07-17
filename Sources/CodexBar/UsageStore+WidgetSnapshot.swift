import CodexBarCore
import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

extension UsageStore {
    func persistWidgetSnapshot(reason: String) {
        let snapshot = self.makeWidgetSnapshot()
        let previousTask = self.widgetSnapshotPersistTask
        self.widgetSnapshotPersistTask = Task { @MainActor in
            _ = await previousTask?.result

            if let override = self._test_widgetSnapshotSaveOverride {
                await override(snapshot)
                return
            }

            await Task.detached(priority: .utility) {
                WidgetSnapshotStore.save(snapshot)
            }.value
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
    }

    private func makeWidgetSnapshot() -> WidgetSnapshot {
        let now = Date()
        let enabledProviders = self.enabledProviders()
        let entries = UsageProvider.allCases.compactMap { provider in
            self.makeWidgetEntry(for: provider, now: now)
        }
        return WidgetSnapshot(
            entries: entries,
            enabledProviders: enabledProviders,
            usageBarsShowUsed: self.settings.usageBarsShowUsed,
            generatedAt: now)
    }

    private func makeWidgetEntry(for provider: UsageProvider, now: Date) -> WidgetSnapshot.ProviderEntry? {
        let snapshot = self.snapshots[provider]
        let storedTokenSnapshot = self.tokenSnapshotForCurrentProviderConfig(for: provider)?.snapshot
        guard snapshot != nil || (provider == .claude && storedTokenSnapshot != nil) else { return nil }

        let tokenSnapshot = storedTokenSnapshot
        let dailyUsage = tokenSnapshot?.daily.map { entry in
            WidgetSnapshot.DailyUsagePoint(
                dayKey: entry.date,
                totalTokens: entry.totalTokens,
                costUSD: entry.costUSD)
        } ?? []

        let tokenUsage = Self.widgetTokenUsageSummary(from: tokenSnapshot, provider: provider)
        let usageRows = snapshot.map { self.widgetUsageRows(provider: provider, snapshot: $0, now: now) } ?? []

        let creditsRemaining: Double?
        let codeReviewRemaining: Double?
        if provider == .codex, let snapshot {
            let projection = self.codexConsumerProjection(
                surface: .widget,
                snapshotOverride: snapshot,
                now: now)
            let displayOnlyExtrasHidden = projection.dashboardVisibility == .displayOnly
            creditsRemaining = displayOnlyExtrasHidden ? nil : projection.credits?.remaining
            codeReviewRemaining = displayOnlyExtrasHidden ? nil : projection.remainingPercent(for: .codeReview)
        } else {
            creditsRemaining = nil
            codeReviewRemaining = nil
        }
        let providerCost: ProviderCostSnapshot? = if provider == .devin,
                                                     self.settings.showOptionalCreditsAndExtraUsage
        {
            snapshot?.providerCost
        } else {
            nil
        }

        return WidgetSnapshot.ProviderEntry(
            provider: provider,
            updatedAt: snapshot?.updatedAt ?? tokenSnapshot?.updatedAt ?? now,
            primary: snapshot?.primary,
            secondary: snapshot?.secondary,
            tertiary: snapshot?.tertiary,
            usageRows: usageRows,
            creditsRemaining: creditsRemaining,
            codeReviewRemainingPercent: codeReviewRemaining,
            tokenUsage: tokenUsage,
            dailyUsage: dailyUsage,
            providerCost: providerCost)
    }

    nonisolated static func widgetTokenUsageSummary(
        from snapshot: CostUsageTokenSnapshot?,
        provider: UsageProvider) -> WidgetSnapshot.TokenUsageSummary?
    {
        guard let snapshot else { return nil }
        let fallbackTokens = snapshot.daily.compactMap(\.totalTokens).reduce(0, +)
        let monthTokensValue = snapshot.last30DaysTokens ?? (fallbackTokens > 0 ? fallbackTokens : nil)
        let sessionLabel = if provider == .bedrock || provider == .mistral {
            "Latest billing day"
        } else if provider == .codex {
            "Today API est. · not billed"
        } else {
            "Today"
        }
        let defaultMonthLabel = snapshot.historyDays == 1 ? "Today" : "\(snapshot.historyDays)d"
        let monthLabel = if provider == .codex {
            "\(snapshot.historyLabel ?? defaultMonthLabel) API est. · not billed"
        } else {
            snapshot.historyLabel ?? defaultMonthLabel
        }
        return WidgetSnapshot.TokenUsageSummary(
            sessionCostUSD: snapshot.sessionCostUSD,
            sessionTokens: snapshot.sessionTokens,
            last30DaysCostUSD: snapshot.last30DaysCostUSD,
            last30DaysTokens: monthTokensValue,
            currencyCode: snapshot.currencyCode,
            sessionLabel: sessionLabel,
            last30DaysLabel: monthLabel,
            updatedAt: snapshot.updatedAt)
    }

    private func widgetUsageRows(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        now: Date) -> [WidgetSnapshot.WidgetUsageRowSnapshot]
    {
        let metadata = ProviderDefaults.metadata[provider]
        if provider == .codex {
            let projection = self.codexConsumerProjection(
                surface: .widget,
                snapshotOverride: snapshot,
                now: now)
            return projection.visibleRateLanes.compactMap { lane in
                guard let window = projection.sourceRateWindow(for: lane) else { return nil }
                let title = switch lane {
                case .session:
                    metadata?.sessionLabel ?? "Session"
                case .weekly:
                    metadata?.weeklyLabel ?? "Weekly"
                }
                return WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: lane.rawValue,
                    title: title,
                    percentLeft: window.remainingPercent,
                    window: window)
            }
        }
        if provider == .antigravity,
           let rows = Self.antigravityQuotaSummaryWidgetRows(snapshot: snapshot),
           !rows.isEmpty
        {
            return rows
        }
        if provider == .antigravity,
           snapshot.primary == nil,
           snapshot.secondary == nil,
           let rows = Self.antigravityLegacyExtraWidgetRows(snapshot: snapshot),
           !rows.isEmpty
        {
            return rows
        }

        let primaryTitle: String = {
            // Legacy request-based Cursor plans track a request quota, not the token-based "Total" pool.
            if provider == .cursor, snapshot.cursorRequests != nil {
                return "Requests"
            }
            if provider == .grok,
               let dyn = GrokProviderDescriptor.primaryLabel(window: snapshot.primary)
            {
                return dyn
            }
            if provider == .doubao,
               let dyn = DoubaoProviderDescriptor.primaryLabel(window: snapshot.primary)
            {
                return dyn
            }
            return metadata?.sessionLabel ?? "Session"
        }()

        var rows: [WidgetSnapshot.WidgetUsageRowSnapshot] = [
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "primary",
                title: primaryTitle,
                percentLeft: snapshot.primary?.remainingPercent),
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "secondary",
                title: metadata?.weeklyLabel ?? "Weekly",
                percentLeft: snapshot.secondary?.remainingPercent),
        ]
        if metadata?.supportsOpus == true {
            rows.append(WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "tertiary",
                title: metadata?.opusLabel ?? "Opus",
                percentLeft: snapshot.tertiary?.remainingPercent))
        }
        if provider == .kimi {
            // Keep persisted widget order stable and include only Kimi's intentional subscription lanes.
            let kimiWindowIDs = ["kimi-monthly", "kimi-code-7d"]
            rows.append(contentsOf: kimiWindowIDs.compactMap { id in
                guard let window = snapshot.extraRateWindows?.first(where: { $0.id == id }), window.usageKnown
                else { return nil }
                return WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: window.id,
                    title: window.title,
                    percentLeft: window.window.remainingPercent)
            })
        }
        return rows.filter { $0.percentLeft != nil }
    }

    private nonisolated static let antigravityQuotaSummaryWindowIDPrefix = "antigravity-quota-summary-"
    private nonisolated static let antigravityCompactFallbackWindowIDPrefix = "antigravity-compact-fallback-"

    private nonisolated static func antigravityQuotaSummaryWidgetRows(
        snapshot: UsageSnapshot) -> [WidgetSnapshot.WidgetUsageRowSnapshot]?
    {
        guard let windows = snapshot.extraRateWindows?.filter({
            $0.id.hasPrefix(Self.antigravityQuotaSummaryWindowIDPrefix)
        }), !windows.isEmpty else {
            return nil
        }
        return windows.map { namedWindow in
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: namedWindow.id,
                title: namedWindow.title,
                percentLeft: namedWindow.usageKnown ? namedWindow.window.remainingPercent : nil)
        }
    }

    private nonisolated static func antigravityLegacyExtraWidgetRows(
        snapshot: UsageSnapshot) -> [WidgetSnapshot.WidgetUsageRowSnapshot]?
    {
        let windows = snapshot.extraRateWindows?
            .filter { $0.id.hasPrefix(Self.antigravityCompactFallbackWindowIDPrefix) && $0.usageKnown }
        guard let windows, !windows.isEmpty else { return nil }
        return windows.map { namedWindow in
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: namedWindow.id,
                title: namedWindow.title,
                percentLeft: namedWindow.window.remainingPercent)
        }
    }
}
