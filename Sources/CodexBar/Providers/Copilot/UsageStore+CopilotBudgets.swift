import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    func clearCopilotBudgetExtras() {
        guard let snapshot = self.snapshots[.copilot],
              snapshot.extraRateWindows?.isEmpty == false
        else { return }

        let updated = UsageSnapshot(
            primary: snapshot.primary,
            secondary: snapshot.secondary,
            tertiary: snapshot.tertiary,
            extraRateWindows: nil,
            kiroUsage: snapshot.kiroUsage,
            providerCost: snapshot.providerCost,
            zaiUsage: snapshot.zaiUsage,
            minimaxUsage: snapshot.minimaxUsage,
            deepseekUsage: snapshot.deepseekUsage,
            openRouterUsage: snapshot.openRouterUsage,
            openAIAPIUsage: snapshot.openAIAPIUsage,
            claudeAdminAPIUsage: snapshot.claudeAdminAPIUsage,
            mistralUsage: snapshot.mistralUsage,
            deepgramUsage: snapshot.deepgramUsage,
            cursorRequests: snapshot.cursorRequests,
            updatedAt: snapshot.updatedAt,
            identity: snapshot.identity)
        self.snapshots[.copilot] = updated
        if self.lastKnownResetSnapshots[.copilot]?.extraRateWindows?.isEmpty == false {
            self.lastKnownResetSnapshots[.copilot] = updated
        }
    }
}
