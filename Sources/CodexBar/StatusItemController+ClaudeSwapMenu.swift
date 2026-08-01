import AppKit
import CodexBarCore

extension StatusItemController {
    func addClaudeSwapMenuCards(
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext)
    {
        let accounts = self.store.claudeSwapAccountSnapshots
        let plan = self.compactAccountPlan(for: .claude, accounts: accounts)
        guard plan.usesCompactLayout else {
            self.addStackedClaudeSwapMenuCards(accounts: accounts, to: menu, captureMenu: captureMenu, context: context)
            return
        }
        self.addCompactAccountMenuRows(
            CompactAccountMenuRendering(
                plan: plan,
                accounts: accounts,
                idPrefix: "claudeSwap",
                cardModel: { [weak self] account in
                    self?.claudeSwapCardModel(for: account)
                },
                planAction: { [weak self] account in
                    self?.claudeSwapAccountSwitchAction(account, menu: captureMenu)
                }),
            to: menu,
            captureMenu: captureMenu,
            context: context)
    }

    private func addStackedClaudeSwapMenuCards(
        accounts: [ProviderAccountUsageSnapshot],
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext)
    {
        let cardRows = accounts.compactMap { account ->
            (account: ProviderAccountUsageSnapshot, model: UsageMenuCardView.Model)? in
            guard let model = self.claudeSwapCardModel(for: account) else { return nil }
            return (account, model)
        }
        self.addStackedMenuCards(
            cardRows.map(\.model),
            to: menu,
            context: context,
            planAction: { [weak self] index in
                guard cardRows.indices.contains(index) else { return nil }
                return self?.claudeSwapAccountSwitchAction(cardRows[index].account, menu: captureMenu)
            })
    }

    private func claudeSwapCardModel(for account: ProviderAccountUsageSnapshot) -> UsageMenuCardView.Model? {
        self.menuCardModel(
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
    }

    private func claudeSwapAccountActionLabel(_ account: ProviderAccountUsageSnapshot) -> String? {
        if account.isActive {
            return L("Active")
        }
        if self.store.claudeSwapTransientState.switchingAccountID == account.id {
            return L("Loading…")
        }
        guard self.store.claudeSwapTransientState.task == nil, account.canActivate else { return nil }
        return L("Switch Account...")
    }

    private func claudeSwapAccountSwitchAction(
        _ account: ProviderAccountUsageSnapshot,
        menu: NSMenu)
        -> (() -> Void)?
    {
        guard self.store.claudeSwapTransientState.task == nil, account.canActivate else { return nil }
        let accountID = account.id
        return { [weak self, weak menu] in
            guard let self else { return }
            self.advanceMenuInteraction(for: menu)
            self.store.switchClaudeSwapAccount(accountID)
        }
    }
}
