import AppKit
import CodexBarCore

extension StatusItemController {
    func addClaudeSwapMenuCards(to menu: NSMenu, context: MenuCardContext) {
        let cardRows = self.store.claudeSwapAccountSnapshots.compactMap { account ->
            (account: ProviderAccountUsageSnapshot, model: UsageMenuCardView.Model)? in
            guard let model = self.menuCardModel(
                for: .claude,
                snapshotOverride: account.snapshot,
                errorOverride: ClaudeSwapAccountProjection.displayError(
                    accountError: account.error,
                    adapterError: self.store.claudeSwapLastError,
                    switchError: self.store.claudeSwapTransientState.lastErrorAccountID == account.id
                        ? self.store.claudeSwapTransientState.lastError
                        : nil),
                forceOverrideCard: account.snapshot == nil,
                accountOverride: AccountInfo(
                    email: account.displayLabel,
                    plan: nil),
                planOverride: self.claudeSwapAccountActionLabel(account))
            else {
                return nil
            }
            return (account, model)
        }
        self.addStackedMenuCards(
            cardRows.map(\.model),
            to: menu,
            context: context,
            planAction: { [weak self] index in
                guard cardRows.indices.contains(index) else { return nil }
                return self?.claudeSwapAccountSwitchAction(cardRows[index].account)
            })
    }

    private func claudeSwapAccountActionLabel(_ account: ProviderAccountUsageSnapshot) -> String? {
        if account.isActive { return L("Active") }
        if self.store.claudeSwapTransientState.switchingAccountID == account.id { return L("Loading…") }
        guard self.store.claudeSwapTransientState.task == nil, account.canActivate else { return nil }
        return L("Switch Account...")
    }

    private func claudeSwapAccountSwitchAction(_ account: ProviderAccountUsageSnapshot) -> (() -> Void)? {
        guard self.store.claudeSwapTransientState.task == nil, account.canActivate else { return nil }
        let accountID = account.id
        return { [weak self] in
            self?.store.switchClaudeSwapAccount(accountID)
        }
    }
}
