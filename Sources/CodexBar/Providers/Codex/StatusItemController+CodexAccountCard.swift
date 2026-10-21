import CodexBarCore

extension UsageStore {
    func codexAccountMenuCardModel(
        for account: CodexVisibleAccount,
        accountSnapshot: CodexAccountUsageSnapshot?) -> UsageMenuCardView.Model?
    {
        self.menuCardModel(
            for: .codex,
            context: .account(.init(
                snapshot: accountSnapshot?.snapshot,
                error: CodexAccountHealth.status(for: account, error: accountSnapshot?.error).label,
                info: AccountInfo(email: account.email, plan: account.workspaceLabel),
                historySelection: self.codexPlanUtilizationHistorySelection(forVisibleAccount: account),
                credits: accountSnapshot?.credits)))
    }
}
