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

    nonisolated static func antigravityStructuredSeriesWindows(
        snapshot: UsageSnapshot) -> [(name: PlanUtilizationSeriesName, window: RateWindow)]
    {
        let summaryRows = (snapshot.extraRateWindows ?? []).filter {
            $0.usageKnown &&
                $0.id.hasPrefix("antigravity-quota-summary-") &&
                !$0.window.isSyntheticPlaceholder &&
                $0.window.usedPercent.isFinite
        }
        guard !summaryRows.isEmpty else { return [] }

        // Provider-specific by design: pin .session and .weekly strictly to the canonical gemini family
        // matching antigravitySessionEquivalentWindows so secondary pools such as Argon never overwrite Gemini history.
        let canonicalGeminiRows = summaryRows.filter {
            Self.antigravityQuotaFamilyKey($0.id) == "gemini"
        }
        let claudeGPTRows = summaryRows.filter {
            AntigravityQuotaFamilyVisibility.knownFamily(windowID: $0.id, title: $0.title) == .claudeGPT
        }

        func mostConstrained(_ rows: [NamedRateWindow], minutes: Int) -> RateWindow? {
            rows
                .filter { $0.window.windowMinutes == minutes }
                .max { lhs, rhs in
                    if lhs.window.usedPercent != rhs.window.usedPercent {
                        return lhs.window.usedPercent < rhs.window.usedPercent
                    }
                    return lhs.id > rhs.id
                }?
                .window
        }

        var result: [(name: PlanUtilizationSeriesName, window: RateWindow)] = []
        if let session = mostConstrained(canonicalGeminiRows, minutes: Self.sessionWindowMinutes) {
            result.append((.session, session))
        }
        if let weekly = mostConstrained(canonicalGeminiRows, minutes: Self.weeklyWindowMinutes) {
            result.append((.weekly, weekly))
        }
        if let claudeSession = mostConstrained(claudeGPTRows, minutes: Self.sessionWindowMinutes) {
            result.append((.antigravityClaudeGPTSession, claudeSession))
        }
        if let claudeWeekly = mostConstrained(claudeGPTRows, minutes: Self.weeklyWindowMinutes) {
            result.append((.antigravityClaudeGPTWeekly, claudeWeekly))
        }
        return result
    }
}
