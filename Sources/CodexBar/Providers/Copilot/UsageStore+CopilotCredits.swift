import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    /// Strips the organization AI credits lane while preserving the seat lane and org login, mirroring
    /// `clearCopilotBudgetExtras()`. Called synchronously from the org-credits toggle's `else` branch so
    /// turning the feature off cannot leave a stale org row on the card if the follow-up refresh fails
    /// (offline, token lost org access, 401) and the last-good snapshot is retained.
    func clearCopilotOrgCredits() {
        if let snapshot = self.snapshots[.copilot],
           let credits = snapshot.copilotCredits,
           credits.org != nil
        {
            let updated = snapshot.with(copilotCredits: credits.clearingOrgLane())
            self.snapshots[.copilot] = updated
            self.lastKnownResetSnapshots[.copilot] = updated
        } else if let resetSnapshot = self.lastKnownResetSnapshots[.copilot],
                  let credits = resetSnapshot.copilotCredits,
                  credits.org != nil
        {
            self.lastKnownResetSnapshots[.copilot] = resetSnapshot.with(copilotCredits: credits.clearingOrgLane())
        }
    }
}
