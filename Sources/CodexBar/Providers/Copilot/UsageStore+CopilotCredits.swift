import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    /// Rewrites the seat "Credits used" row when the user changes or clears the per-seat entitlement,
    /// mirroring `clearCopilotBudgetExtras()`. Called synchronously from the settings field's binding
    /// setter so editing the value cannot leave a stale denominator/bar on the card if the follow-up
    /// refresh never lands (offline, token lost, 401) and the last-good snapshot is retained.
    func updateCopilotSeatCreditEntitlement(_ entitlement: Double?) {
        if let snapshot = self.snapshots[.copilot],
           let updated = snapshot.updatingCopilotSeatCreditEntitlement(entitlement)
        {
            self.snapshots[.copilot] = updated
            self.lastKnownResetSnapshots[.copilot] = updated
        } else if let resetSnapshot = self.lastKnownResetSnapshots[.copilot],
                  let updated = resetSnapshot.updatingCopilotSeatCreditEntitlement(entitlement)
        {
            self.lastKnownResetSnapshots[.copilot] = updated
        }
    }
}

extension UsageSnapshot {
    /// Returns a copy with the seat credits row rebuilt for `entitlement`, or `nil` when nothing
    /// changed (no row, or a row that carries no numeric usage at all — the next refresh must
    /// rebuild it). The numerator comes from `row.progress.used`, falling back to the retained
    /// `row.usageValue` on text-only rows, never re-parsed from the display string. That fallback
    /// is what lets a cached text-only row grow a bar the moment an entitlement is entered, even
    /// when the follow-up refresh never lands (offline, token lost, 401).
    func updatingCopilotSeatCreditEntitlement(_ entitlement: Double?) -> UsageSnapshot? {
        guard self.details.lazy.flatMap(\.rows)
            .contains(where: {
                $0.id == CopilotCreditDetailRows.seatRowID && ($0.progress != nil || $0.usageValue != nil)
            })
        else { return nil }
        let details = self.details.map { section -> ProviderDetailSection in
            let rows = section.rows.map { row -> ProviderDetailSection.Row in
                guard row.id == CopilotCreditDetailRows.seatRowID, let used = row.progress?.used ?? row.usageValue
                else { return row }
                let value: String
                let progress: ProviderDetailSection.Row.Progress?
                if let entitlement {
                    guard let rebuilt = try? ProviderDetailSection.Row.Progress(used: used, total: entitlement)
                    else { return row }
                    value = "\(UsageFormatter.creditsNumberString(from: used)) / " +
                        UsageFormatter.creditsNumberString(from: entitlement)
                    progress = rebuilt
                } else {
                    value = UsageFormatter.creditsNumberString(from: used)
                    progress = nil
                }
                return (try? ProviderDetailSection.Row(
                    id: row.id,
                    label: row.label,
                    value: value,
                    secondaryValue: row.secondaryValue,
                    progress: progress,
                    usageValue: used)) ?? row
            }
            return (try? ProviderDetailSection(title: section.title, rows: rows, chart: section.chart)) ?? section
        }
        return self.with(details: details)
    }
}
