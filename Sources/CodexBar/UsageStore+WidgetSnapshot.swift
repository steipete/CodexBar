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
        let enabledProviders = self.enabledProviders()
        let entries = UsageProvider.allCases.compactMap { provider in
            self.makeWidgetEntry(for: provider)
        }
        return WidgetSnapshot(entries: entries, enabledProviders: enabledProviders, generatedAt: Date())
    }

    private func makeWidgetEntry(for provider: UsageProvider) -> WidgetSnapshot.ProviderEntry? {
        guard let snapshot = self.snapshots[provider] else { return nil }

        let tokenSnapshot = self.tokenSnapshot(fromProviderSnapshot: snapshot, provider: provider) ?? self
            .tokenSnapshots[provider]
        let dailyUsage = tokenSnapshot?.daily.map { entry in
            WidgetSnapshot.DailyUsagePoint(
                dayKey: entry.date,
                totalTokens: entry.totalTokens,
                costUSD: entry.costUSD)
        } ?? []

        let tokenUsage = Self.widgetTokenUsageSummary(from: tokenSnapshot, provider: provider)
        let usageRows = self.widgetUsageRows(provider: provider, snapshot: snapshot)

        let creditsRemaining: Double?
        let codeReviewRemaining: Double?
        if provider == .codex {
            let projection = self.codexConsumerProjection(
                surface: .widget,
                snapshotOverride: snapshot,
                now: snapshot.updatedAt)
            let displayOnlyExtrasHidden = projection.dashboardVisibility == .displayOnly
            creditsRemaining = displayOnlyExtrasHidden ? nil : projection.credits?.remaining
            codeReviewRemaining = displayOnlyExtrasHidden ? nil : projection.remainingPercent(for: .codeReview)
        } else {
            creditsRemaining = nil
            codeReviewRemaining = nil
        }

        return WidgetSnapshot.ProviderEntry(
            provider: provider,
            updatedAt: snapshot.updatedAt,
            primary: snapshot.primary,
            secondary: snapshot.secondary,
            tertiary: snapshot.tertiary,
            usageRows: usageRows,
            creditsRemaining: creditsRemaining,
            codeReviewRemainingPercent: codeReviewRemaining,
            tokenUsage: tokenUsage,
            dailyUsage: dailyUsage)
    }

    private nonisolated static func widgetTokenUsageSummary(
        from snapshot: CostUsageTokenSnapshot?,
        provider: UsageProvider) -> WidgetSnapshot.TokenUsageSummary?
    {
        guard let snapshot else { return nil }
        let fallbackTokens = snapshot.daily.compactMap(\.totalTokens).reduce(0, +)
        let monthTokensValue = snapshot.last30DaysTokens ?? (fallbackTokens > 0 ? fallbackTokens : nil)
        let sessionLabel = provider == .bedrock || provider == .mistral ? "Latest billing day" : "Today"
        let monthLabel = snapshot.historyLabel ?? (snapshot.historyDays == 1 ? "Today" : "\(snapshot.historyDays)d")
        return WidgetSnapshot.TokenUsageSummary(
            sessionCostUSD: snapshot.sessionCostUSD,
            sessionTokens: snapshot.sessionTokens,
            last30DaysCostUSD: snapshot.last30DaysCostUSD,
            last30DaysTokens: monthTokensValue,
            currencyCode: snapshot.currencyCode,
            sessionLabel: sessionLabel,
            last30DaysLabel: monthLabel)
    }

    private func widgetUsageRows(
        provider: UsageProvider,
        snapshot: UsageSnapshot) -> [WidgetSnapshot.WidgetUsageRowSnapshot]
    {
        let metadata = ProviderDefaults.metadata[provider]
        if provider == .codex {
            let projection = self.codexConsumerProjection(
                surface: .widget,
                snapshotOverride: snapshot,
                now: snapshot.updatedAt)
            return projection.visibleRateLanes.compactMap { lane in
                guard let window = projection.rateWindow(for: lane) else { return nil }
                let title = switch lane {
                case .session:
                    metadata?.sessionLabel ?? "Session"
                case .weekly:
                    metadata?.weeklyLabel ?? "Weekly"
                }
                return WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: lane.rawValue,
                    title: title,
                    percentLeft: window.remainingPercent)
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
            if provider == .grok,
               let dyn = GrokProviderDescriptor.primaryLabel(window: snapshot.primary)
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
