import CodexBarCore
import Foundation

extension CodexProviderImplementation {
    /// Every visible Codex account; saved managed accounts can be promoted to the System account.
    @MainActor
    func systemAccountMenuEntries(context: SystemAccountSwitchContext) -> SystemAccountMenuEntries? {
        let projection = context.settings.codexVisibleAccountProjection
        guard !projection.visibleAccounts.isEmpty else { return nil }
        let ordinals = CodexAccountSwitcherLabeling.ordinals(for: projection.visibleAccounts)
        let hidePersonalInfo = context.settings.hidePersonalInfo
        return SystemAccountMenuEntries(
            cliName: "Codex",
            isBlocked: context.codexAccountPromotionCoordinator?.isInteractionBlocked() ?? false,
            entries: projection.visibleAccounts.map { account in
                SystemAccountMenuEntry(
                    accountID: account.id,
                    title: CodexAccountSwitcherLabeling.label(
                        for: account,
                        ordinal: ordinals[account.id],
                        hidePersonalInfo: hidePersonalInfo),
                    isSystem: account.id == projection.liveVisibleAccountID,
                    isSwitchable: account.storedAccountID != nil)
            })
    }

    @MainActor
    func switchSystemAccount(accountID: String, context: SystemAccountSwitchContext) async
        -> SystemAccountSwitchOutcome
    {
        guard let coordinator = context.codexAccountPromotionCoordinator,
              let managedAccountID = context.settings.codexVisibleAccountProjection.visibleAccounts
                  .first(where: { $0.id == accountID })?.storedAccountID
        else {
            return .failed(
                title: L("Could not switch system account"),
                message: L("That account can no longer be switched to."))
        }
        switch await coordinator.promote(managedAccountID: managedAccountID) {
        case .success:
            return .succeeded
        case let .failure(error):
            return .failed(title: error.title, message: error.message)
        }
    }
}
