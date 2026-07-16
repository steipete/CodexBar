import CodexBarCore
import Foundation

extension UsageStore {
    nonisolated static func limitResetBoundaryAdvanced(
        previous: Date?,
        current: Date?,
        requiresPreviousBoundary: Bool = false,
        requiresCurrentBoundary: Bool = true) -> Bool
    {
        guard let previous else { return !requiresPreviousBoundary }
        // A missing current boundary cannot confirm an advance. Callers that trust
        // boundary-less snapshots (e.g. Claude OAuth, which may omit resetsAt on a genuine
        // reset) pass requiresCurrentBoundary: false so the crossing is still allowed.
        guard let current else { return !requiresCurrentBoundary }
        return !self.areEquivalentPlanUtilizationResetBoundaries(previous, current) && current > previous
    }

    /// Whether a weekly below-threshold crossing should post a limit-reset celebration.
    ///
    /// Codex boundaries are always present, so a real advance requires both a prior and a
    /// current boundary (#2054). Claude OAuth snapshots may legitimately omit the boundary, so
    /// neither is required: only a confirmed *unchanged* boundary is suppressed as a suspect
    /// near-zero sample (#2222); a missing boundary on either side still allows a genuine reset.
    nonisolated static func weeklyResetBoundaryAllowsCelebration(
        provider: UsageProvider,
        previous: Date?,
        current: Date?) -> Bool
    {
        let isCodex = provider == .codex
        return self.limitResetBoundaryAdvanced(
            previous: previous,
            current: current,
            requiresPreviousBoundary: isCodex,
            requiresCurrentBoundary: isCodex)
    }
}
