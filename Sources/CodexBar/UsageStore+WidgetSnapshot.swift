import CodexBarCore
import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

extension UsageStore {
    func persistWidgetSnapshot(reason: String) {
        let snapshot = self.makeWidgetSnapshot()
        Task.detached(priority: .utility) {
            WidgetSnapshotStore.save(snapshot)
            #if canImport(WidgetKit)
            await MainActor.run {
                WidgetCenter.shared.reloadAllTimelines()
            }
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

        let tokenSnapshot = self.tokenSnapshots[provider]
        let dailyUsage = tokenSnapshot?.daily.map { entry in
            WidgetSnapshot.DailyUsagePoint(
                dayKey: entry.date,
                totalTokens: entry.totalTokens,
                costUSD: entry.costUSD)
        } ?? []

        let tokenUsage = Self.widgetTokenUsageSummary(from: tokenSnapshot)
        let creditsRemaining = provider == .codex ? self.credits?.remaining : nil
        let codeReviewRemaining = provider == .codex ? self.openAIDashboard?.codeReviewRemainingPercent : nil

        return WidgetSnapshot.ProviderEntry(
            provider: provider,
            updatedAt: snapshot.updatedAt,
            primary: snapshot.primary,
            secondary: snapshot.secondary,
            tertiary: snapshot.tertiary,
            creditsRemaining: creditsRemaining,
            codeReviewRemainingPercent: codeReviewRemaining,
            tokenUsage: tokenUsage,
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
}
