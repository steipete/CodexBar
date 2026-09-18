import CodexBarCore
import Foundation

extension UsageStore {
    nonisolated static func latestObservationHourEntries(
        existingHourEntries: [PlanUtilizationHistoryEntry],
        incomingEntry: PlanUtilizationHistoryEntry) -> [PlanUtilizationHistoryEntry]
    {
        // A cadence-less balance may fall without reset metadata; retain its latest value and capture time.
        let latest = existingHourEntries.last
        return [latest.map { $0.capturedAt > incomingEntry.capturedAt ? $0 : incomingEntry } ?? incomingEntry]
    }

    nonisolated static func antigravityHistoryUsesObservations(
        snapshot: UsageSnapshot?, histories: [PlanUtilizationSeriesHistory]) -> Bool
    {
        if let snapshot {
            if self.hasSupportedAntigravityQuotaSummary(snapshot) { return false }
            if !self.antigravityQuotaObservationSamples(snapshot: snapshot, capturedAt: snapshot.updatedAt).isEmpty {
                return true
            }
        }
        // During startup/unavailability, use the most recently captured format; ties favor structured windows.
        // Both sets remain persisted. A stale observation must not hide newer structured history.
        let supported = histories.filter(\.hasSupportedCadence)
        let observations = supported.filter(\.name.isQuotaObservation).compactMap(\.latestCapturedAt).max()
        let structured = supported.filter { !$0.name.isQuotaObservation }.compactMap(\.latestCapturedAt).max()
        return (observations ?? .distantPast) > (structured ?? .distantPast)
    }

    nonisolated static func antigravityQuotaObservationSamples(
        snapshot: UsageSnapshot,
        capturedAt: Date) -> [PlanUtilizationSeriesSample]
    {
        guard !self.hasSupportedAntigravityQuotaSummary(snapshot) else { return [] }
        let lanes: [(PlanUtilizationSeriesName, RateWindow?)] = [
            (.antigravityGemini, snapshot.primary),
            (.antigravityClaudeGPT, snapshot.secondary),
        ]
        return lanes.compactMap { name, window in
            guard let window, !window.isSyntheticPlaceholder, window.usedPercent.isFinite else { return nil }
            return PlanUtilizationSeriesSample(
                name: name,
                windowMinutes: 0,
                entry: PlanUtilizationHistoryEntry(
                    capturedAt: capturedAt,
                    usedPercent: min(100, max(0, window.usedPercent)),
                    resetsAt: window.resetsAt))
        }
    }

    private nonisolated static func hasSupportedAntigravityQuotaSummary(_ snapshot: UsageSnapshot) -> Bool {
        snapshot.extraRateWindows?.contains {
            $0.id.hasPrefix("antigravity-quota-summary-") && $0.usageKnown
                && !$0.window.isSyntheticPlaceholder && $0.window.usedPercent.isFinite
                && [self.sessionWindowMinutes, self.weeklyWindowMinutes].contains($0.window.windowMinutes ?? 0)
        } == true
    }
}
