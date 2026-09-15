import CodexBarCore
import Foundation

extension ClaudeProviderImplementation {
    /// claude-swap accounts, offered only while claude-swap owns Claude account presentation.
    @MainActor
    func systemAccountMenuEntries(context: SystemAccountSwitchContext) -> SystemAccountMenuEntries? {
        let store = context.store
        guard store.shouldFetchClaudeSwapAccounts(),
              ClaudeSwapMenuPrecedence.prefersClaudeSwap(
                  provider: .claude,
                  accountCount: store.claudeSwapAccountSnapshots.count,
                  showSingleAccount: context.settings.claudeSwapShowSingleAccount)
        else { return nil }
        let hidePersonalInfo = context.settings.hidePersonalInfo
        return SystemAccountMenuEntries(
            cliName: "Claude Code",
            isBlocked: store.claudeSwapTransientState.task != nil,
            entries: store.claudeSwapAccountSnapshots.map { account in
                SystemAccountMenuEntry(
                    accountID: account.id.opaqueID,
                    title: ClaudeSwapAccountMenuDisplay.label(for: account, hidePersonalInfo: hidePersonalInfo),
                    isSystem: account.isActive,
                    isSwitchable: account.canActivate)
            })
    }

    /// Runs the serialized `cswap --switch-to` transaction and reads its result from the store, which already
    /// scopes errors to the requested slot and discards results from a superseded adapter configuration.
    @MainActor
    func switchSystemAccount(accountID: String, context: SystemAccountSwitchContext) async
        -> SystemAccountSwitchOutcome
    {
        let store = context.store
        let id = ProviderAccountIdentity(source: ClaudeSwapAccountProjection.sourceName, opaqueID: accountID)
        let configuration = store.claudeSwapConfigurationKey
        guard let task = store.switchClaudeSwapAccount(id) else {
            return .failed(
                title: L("Could not switch system account"),
                message: L("That account can no longer be switched to."))
        }
        await task.value
        guard store.claudeSwapConfigurationKey == configuration else { return .discarded }
        if store.claudeSwapTransientState.lastErrorAccountID == id,
           let message = store.claudeSwapTransientState.lastError
        {
            return .failed(title: L("Could not switch system account"), message: message)
        }
        return .succeeded
    }
}
