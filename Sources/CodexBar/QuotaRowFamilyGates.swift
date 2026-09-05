import CodexBarCore
import Foundation

/// Family-level extra-usage gates that `extraRateWindowMetrics` already applies after per-row hidden IDs.
///
/// The quota-row settings pane must consult the same gates so a checkbox cannot claim a row is visible
/// (or that “Show all” can restore it) while the menu would strip it.
struct QuotaRowFamilyGates: Equatable, Sendable {
    let provider: UsageProvider
    let showOptionalCreditsAndExtraUsage: Bool
    let claudeDailyRoutinesUsageVisible: Bool
    let codexSparkUsageVisible: Bool
    let copilotBudgetExtrasEnabled: Bool

    /// Whether family-level settings allow this extra window to appear in the menu.
    /// Independent of `hiddenQuotaRowIDs`.
    func allows(id: String) -> Bool {
        // Provider-specific by design: Codex extras, Copilot budget extras, Spark, and Claude Daily
        // Routines are owned by existing family toggles rather than the per-row hidden-ID set.
        if self.provider == .codex, !self.showOptionalCreditsAndExtraUsage {
            return false
        }
        if self.provider == .copilot, !self.copilotBudgetExtrasEnabled {
            return false
        }
        if self.provider == .codex, !self.codexSparkUsageVisible, Self.isCodexSparkRateWindowID(id) {
            return false
        }
        if self.provider == .claude,
           !self.showOptionalCreditsAndExtraUsage || !self.claudeDailyRoutinesUsageVisible,
           Self.isClaudeDailyRoutinesRateWindowID(id)
        {
            return false
        }
        return true
    }

    func allows(_ window: NamedRateWindow) -> Bool {
        self.allows(id: window.id)
    }

    func filter(_ windows: [NamedRateWindow]) -> [NamedRateWindow] {
        windows.filter { self.allows($0) }
    }

    /// Extra windows the menu would render after family gates and the per-row hidden-ID set.
    func menuVisibleWindows(
        _ windows: [NamedRateWindow],
        hiddenIDs: Set<String>) -> [NamedRateWindow]
    {
        let familyVisible = self.filter(windows)
        guard !hiddenIDs.isEmpty else { return familyVisible }
        return familyVisible.filter { !hiddenIDs.contains($0.id) }
    }

    static func isCodexSparkRateWindowID(_ id: String) -> Bool {
        id == CodexAdditionalRateLimitMapper.sparkWindowID ||
            id == CodexAdditionalRateLimitMapper.sparkWeeklyWindowID
    }

    static func isClaudeDailyRoutinesRateWindowID(_ id: String) -> Bool {
        id == "claude-routines"
    }
}

/// Settings-pane listing: snapshot extras that can actually appear, plus still-hidden rows the
/// provider stopped reporting — never family-gated rows, which the family toggle owns.
enum QuotaRowVisibilityListing {
    static func rows(
        reported: [NamedRateWindow],
        hiddenIDs: Set<String>,
        gates: QuotaRowFamilyGates) -> [NamedRateWindow]
    {
        let familyVisible = gates.filter(reported)
        var seen = Set(familyVisible.map(\.id))
        var rows = familyVisible
        for hiddenID in hiddenIDs.sorted() where seen.insert(hiddenID).inserted && gates.allows(id: hiddenID) {
            rows.append(NamedRateWindow(
                id: hiddenID,
                title: hiddenID,
                window: RateWindow(
                    usedPercent: 0,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: nil)))
        }
        return rows
    }

    static func hasIndependentlyHiddenRows(
        listed: [NamedRateWindow],
        hiddenIDs: Set<String>) -> Bool
    {
        listed.contains { hiddenIDs.contains($0.id) }
    }
}
