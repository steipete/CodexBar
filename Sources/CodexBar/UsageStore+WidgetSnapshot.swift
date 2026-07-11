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
        let entries = UsageProvider.allCases.flatMap { provider in
            self.makeWidgetEntries(for: provider)
        }
        return WidgetSnapshot(entries: entries, enabledProviders: enabledProviders, generatedAt: Date())
    }

    private func makeWidgetEntries(for provider: UsageProvider) -> [WidgetSnapshot.ProviderEntry] {
        guard provider == .opencode else {
            return self.makeWidgetEntry(for: provider).map { [$0] } ?? []
        }
        let accounts = self.settings.opencodeWorkspaceAccounts.accounts
        guard !accounts.isEmpty else {
            return self.makeWidgetEntry(for: provider).map { [$0] } ?? []
        }
        let activeID = self.settings.activeOpenCodeWorkspaceAccount?.id
        let orderedAccounts = accounts.sorted { first, second in
            let firstIsActive = first.id == activeID
            let secondIsActive = second.id == activeID
            if firstIsActive != secondIsActive {
                return firstIsActive
            }
            return first.id < second.id
        }
        return orderedAccounts.compactMap { account in
            let snapshot = self.openCodeWorkspaceSnapshots[account.id]
                ?? (account.id == activeID ? self.snapshots[provider] : nil)
                ?? UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date())
            return self.makeWidgetEntry(
                for: provider,
                snapshot: snapshot,
                accountID: account.id,
                accountLabel: account.ownerLabel.map { "\(account.label) · \($0)" } ?? account.label)
        }
    }

    private func makeWidgetEntry(
        for provider: UsageProvider,
        snapshot overrideSnapshot: UsageSnapshot? = nil,
        accountID: String? = nil,
        accountLabel: String? = nil) -> WidgetSnapshot.ProviderEntry?
    {
        guard let snapshot = overrideSnapshot ?? self.snapshots[provider] else { return nil }

        let tokenSnapshot = self.tokenSnapshots[provider]
        let dailyUsage = tokenSnapshot?.daily.map { entry in
            WidgetSnapshot.DailyUsagePoint(
                dayKey: entry.date,
                totalTokens: entry.totalTokens,
                costUSD: entry.costUSD)
        } ?? []

        let selectedCursorRange = provider == .cursor ? self.settings.cursorUsageRangeKind : nil
        let cursorSummary = selectedCursorRange.flatMap { range in
            let summaries = snapshot.cursorRangeSummaries ?? []
            if let selected = summaries.first(where: { $0.rangeKind == range }) {
                return selected
            }
            guard summaries.count == 1 else { return nil }
            return summaries.first
        }
        let tokenUsage = cursorSummary.map(Self.widgetCursorTokenUsageSummary(from:))
            ?? Self.widgetTokenUsageSummary(from: tokenSnapshot)
        let cursorRequestRange = cursorSummary.map {
            WidgetSnapshot.CursorRequestRange(start: $0.range.start, end: $0.range.end, label: $0.rangeKind.label)
        }
        let cursorRequestDetails = cursorSummary.map { summary in
            summary.recentRequests
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(30)
                .map { request in
                let normalized = CursorModelNormalizer.normalize(request.model)
                return WidgetSnapshot.CursorRequestDetail(
                    timestamp: request.timestamp,
                    model: request.model,
                    tokens: request.tokens,
                    requests: request.requests,
                    requestCost: request.requestCost,
                    compactModel: UsageFormatter.cursorCompactModelLabel(normalized),
                    estimateText: UsageFormatter.cursorEstimateText(CursorRequestCostEstimator.estimate(for: request)))
            }
        }
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
            accountID: accountID,
            accountLabel: accountLabel,
            usageRows: usageRows,
            creditsRemaining: creditsRemaining,
            codeReviewRemainingPercent: codeReviewRemaining,
            tokenUsage: tokenUsage,
            cursorRequestRange: cursorRequestRange,
            cursorRequestDetails: cursorRequestDetails,
            dailyUsage: dailyUsage)
    }

    private nonisolated static func widgetTokenUsageSummary(
        from snapshot: CostUsageTokenSnapshot?) -> WidgetSnapshot.TokenUsageSummary?
    {
        guard let snapshot else { return nil }
        let fallbackTokens = snapshot.daily.compactMap(\.totalTokens).reduce(0, +)
        let monthTokensValue = snapshot.last30DaysTokens ?? (fallbackTokens > 0 ? fallbackTokens : nil)
        return WidgetSnapshot.TokenUsageSummary(
            sessionCostUSD: snapshot.sessionCostUSD,
            sessionTokens: snapshot.sessionTokens,
            last30DaysCostUSD: snapshot.last30DaysCostUSD,
            last30DaysTokens: monthTokensValue)
    }

    private nonisolated static func widgetCursorTokenUsageSummary(
        from summary: CursorRangeUsageSummary) -> WidgetSnapshot.TokenUsageSummary
    {
        let exactCost = summary.requestCostSummary?.exactUSD.map { NSDecimalNumber(decimal: $0).doubleValue }
        return WidgetSnapshot.TokenUsageSummary(
            sessionCostUSD: exactCost,
            sessionTokens: summary.tokens,
            last30DaysCostUSD: exactCost,
            last30DaysTokens: summary.tokens,
            sessionCostText: UsageFormatter.cursorEstimatedTotalText(summary.requestCostSummary))
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

        let rows: [WidgetSnapshot.WidgetUsageRowSnapshot] = [
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "primary",
                title: metadata?.sessionLabel ?? "Session",
                percentLeft: snapshot.primary?.remainingPercent),
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "secondary",
                title: metadata?.weeklyLabel ?? "Weekly",
                percentLeft: snapshot.secondary?.remainingPercent),
        ]
        return rows.filter { $0.percentLeft != nil }
    }
}
