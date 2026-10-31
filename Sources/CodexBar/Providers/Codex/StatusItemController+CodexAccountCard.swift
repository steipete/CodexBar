import CodexBarCore

extension UsageStore {
    func codexMenuAccountName(for provider: UsageProvider, context: UsageMenuCardContext) -> String? {
        guard provider == .codex, !context.isSettings, context.account == nil,
              !self.settings.hidePersonalInfo, self.settings.codexUsageDataSource != .pat,
              self.lastSourceLabels[.codex] != "pat",
              let account = self.settings.codexVisibleAccountProjectionForMenuDisplay?.visibleAccounts
                  .first(where: { $0.isActive }),
                  account.customName != nil
        else { return nil }
        return account.menuDisplayName
    }

    func codexAccountMenuCardModel(
        for account: CodexVisibleAccount,
        accountSnapshot: CodexAccountUsageSnapshot?) -> UsageMenuCardView.Model?
    {
        var model = self.menuCardModel(
            for: .codex,
            context: .account(.init(
                snapshot: accountSnapshot?.snapshot,
                error: CodexAccountHealth.status(for: account, error: accountSnapshot?.error).label,
                info: AccountInfo(email: account.email, plan: account.workspaceLabel),
                historySelection: self.codexPlanUtilizationHistorySelection(forVisibleAccount: account),
                credits: accountSnapshot?.credits)))
        if account.customName != nil, !self.settings.hidePersonalInfo {
            model.providerName = account.menuDisplayName
        }
        return model
    }
}
