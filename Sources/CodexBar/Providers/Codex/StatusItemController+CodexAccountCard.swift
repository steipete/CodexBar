import CodexBarCore

extension StatusItemController {
    func codexAccountMenuCardModel(
        for account: CodexVisibleAccount,
        accountSnapshot: CodexAccountUsageSnapshot?) -> UsageMenuCardView.Model?
    {
        self.menuCardModel(
            for: .codex,
            context: .account(.init(
                snapshot: accountSnapshot?.snapshot,
                error: CodexAccountHealth.status(for: account, error: accountSnapshot?.error).label,
                info: self.accountInfo(for: account),
                historySelection: self.store.codexPlanUtilizationHistorySelection(forVisibleAccount: account),
                credits: accountSnapshot?.credits)))
    }
}
