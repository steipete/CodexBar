import CodexBarCore
import Foundation
@testable import CodexBar

extension UsageStore {
    nonisolated static func _updatedPlanUtilizationEntriesForTesting(
        existingEntries: [PlanUtilizationHistoryEntry],
        entry: PlanUtilizationHistoryEntry) -> [PlanUtilizationHistoryEntry]?
    {
        var entries = existingEntries
        guard self.updatedPlanUtilizationEntries(existingEntries: &entries, entry: entry) else {
            return nil
        }
        return entries
    }

    nonisolated static func _planUtilizationEntryUpperBoundForTesting(
        entries: [PlanUtilizationHistoryEntry],
        capturedAt: Date) -> Int
    {
        self.planUtilizationEntryUpperBound(entries: entries, capturedAt: capturedAt)
    }

    nonisolated static func _updatedPlanUtilizationHistoriesForTesting(
        existingHistories: [PlanUtilizationSeriesHistory],
        samples: [PlanUtilizationSeriesHistory]) -> [PlanUtilizationSeriesHistory]?
    {
        let normalized = samples.flatMap { history in
            history.entries.map { entry in
                PlanUtilizationSeriesSample(name: history.name, windowMinutes: history.windowMinutes, entry: entry)
            }
        }
        return self.updatedPlanUtilizationHistories(existingHistories: existingHistories, samples: normalized)
    }

    nonisolated static var _planUtilizationMaxSamplesForTesting: Int {
        self.planUtilizationMaxSamples
    }

    nonisolated static func _planUtilizationAccountKeyForTesting(
        provider: UsageProvider,
        snapshot: UsageSnapshot) -> String?
    {
        self.planUtilizationIdentityAccountKey(provider: provider, snapshot: snapshot)
    }

    nonisolated static func _planUtilizationTokenAccountKeyForTesting(
        provider: UsageProvider,
        account: ProviderTokenAccount) -> String?
    {
        self.planUtilizationAccountKey(provider: provider, account: account)
    }

    nonisolated static func _claudeOAuthPlanUtilizationAccountKeyForTesting(
        historyOwnerIdentifier: String?) -> String?
    {
        self.claudeOAuthPlanUtilizationAccountKey(
            historyOwnerIdentifier: historyOwnerIdentifier)
    }

    nonisolated static func _legacyClaudePlanUtilizationEmailAccountKeyForTesting(snapshot: UsageSnapshot) -> String? {
        self.legacyClaudePlanUtilizationEmailAccountKey(snapshot: snapshot)
    }

    nonisolated static func _codexLegacyPlanUtilizationEmailHashKeyForTesting(
        normalizedEmail: String) -> String
    {
        self.codexLegacyPlanUtilizationEmailHashKey(for: normalizedEmail)
    }
}
