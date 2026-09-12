import CodexBarCore

extension StatusItemController {
    func codexAccountMenuCardModel(
        for account: CodexVisibleAccount,
        accountSnapshot: CodexAccountUsageSnapshot?) -> UsageMenuCardView.Model?
    {
        self.menuCardModel(
            for: .codex,
            snapshotOverride: accountSnapshot?.snapshot,
            errorOverride: CodexAccountHealth.status(for: account, error: accountSnapshot?.error).label,
            accountOverride: self.accountInfo(for: account),
            historySelectionOverride: self.store.codexPlanUtilizationHistorySelection(forVisibleAccount: account),
            creditsOverride: accountSnapshot?.credits)
    }
}
