import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    /// Strips the organization AI credits row while preserving the rest of the card, mirroring
    /// `clearCopilotBudgetExtras()`. Called synchronously from the org-credits toggle's `else` branch so
    /// turning the feature off cannot leave a stale org row on the card if the follow-up refresh fails
    /// (offline, token lost org access, 401) and the last-good snapshot is retained.
    func clearCopilotOrgCredits() {
        if let snapshot = self.snapshots[.copilot],
           let updated = snapshot.removingCopilotOrgCreditsRow()
        {
            self.snapshots[.copilot] = updated
            self.lastKnownResetSnapshots[.copilot] = updated
        } else if let resetSnapshot = self.lastKnownResetSnapshots[.copilot],
                  let updated = resetSnapshot.removingCopilotOrgCreditsRow()
        {
            self.lastKnownResetSnapshots[.copilot] = updated
        }
    }
}

extension UsageSnapshot {
    /// Returns a copy without the org AI credits detail row, or `nil` when nothing changed.
    /// Sections emptied by the removal are dropped with the row.
    func removingCopilotOrgCreditsRow() -> UsageSnapshot? {
        guard self.details.lazy.flatMap(\.rows).contains(where: { $0.id == CopilotCreditDetailRows.orgRowID })
        else { return nil }
        let details = self.details.compactMap { section -> ProviderDetailSection? in
            let rows = section.rows.filter { $0.id != CopilotCreditDetailRows.orgRowID }
            guard rows.count != section.rows.count else { return section }
            guard !rows.isEmpty || section.chart != nil else { return nil }
            return try? ProviderDetailSection(title: section.title, rows: rows, chart: section.chart)
        }
        return self.with(details: details)
    }
}
