import CodexBarCore

extension StatusItemController {
    func codexAccountMenuCardModel(
        for account: CodexVisibleAccount,
        accountSnapshot: CodexAccountUsageSnapshot?) -> UsageMenuCardView.Model?
    {
        let model = self.menuCardModel(
            for: .codex,
            context: .account(.init(
                snapshot: accountSnapshot?.snapshot,
                error: CodexAccountHealth.status(for: account, error: accountSnapshot?.error).label,
                info: self.accountInfo(for: account),
                historySelection: self.store.codexPlanUtilizationHistorySelection(forVisibleAccount: account),
                credits: accountSnapshot?.credits)))
        // Stacked and compact layouts render one card per account; switch feedback belongs on its target's card.
        return model?.applyingSwitchFeedback(
            self.systemAccountSwitchDisplayFeedback(for: .codex).subtitle(for: .codex, accountID: account.id))
    }
}
