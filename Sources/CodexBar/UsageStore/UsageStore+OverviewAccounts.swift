import CodexBarCore
import Foundation

struct MergedOverviewRow {
    let provider: ProviderInstanceID
    let accountID: String?
    let model: UsageMenuCardView.Model?

    var id: String {
        self.provider.rawValue + (self.accountID.map { "/account/" + $0 } ?? "")
    }

    static func providerID(from rowID: String) -> ProviderInstanceID? {
        ProviderInstanceID(rawValue: rowID.components(separatedBy: "/account/")[0])
    }
}

extension UsageStore {
    func tokenAccountMenuCardModel(
        for provider: UsageProvider,
        accountSnapshot: TokenAccountUsageSnapshot) -> UsageMenuCardView.Model?
    {
        let label = accountSnapshot.account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.menuCardModel(
            for: provider,
            context: .account(.init(
                snapshot: accountSnapshot.snapshot,
                error: accountSnapshot.error,
                info: AccountInfo(email: label.isEmpty ? nil : label, plan: nil),
                historySelection: self.planUtilizationHistorySelection(
                    for: provider,
                    account: accountSnapshot.account),
                tokenAccountID: accountSnapshot.account.id)))
    }

    /// Expand only the already-selected providers; account rows do not consume provider slots.
    func mergedOverviewRows(for providers: [ProviderInstanceID]) -> [MergedOverviewRow] {
        providers.flatMap { instanceID -> [MergedOverviewRow] in
            guard let provider = instanceID.firstPartyProvider else {
                return UserProviderPluginRegistry.plugin(for: instanceID) == nil
                    ? [] : [MergedOverviewRow(provider: instanceID, accountID: nil, model: nil)]
            }
            if self.settings.mergedOverviewAllAccounts {
                let accounts = self.mergedOverviewAccountRows(for: provider)
                if !accounts.isEmpty { return accounts }
            }
            let model = self.menuCardModel(for: provider)
            return model.isOverviewErrorOnly ? [] : [MergedOverviewRow(
                provider: instanceID, accountID: nil, model: model)]
        }
    }

    private func mergedOverviewAccountRows(for provider: UsageProvider) -> [MergedOverviewRow] {
        if ClaudeSwapMenuPrecedence.prefersClaudeSwap(
            provider: provider,
            accountCount: self.claudeSwapAccountSnapshots.count,
            showSingleAccount: self.settings.claudeSwapShowSingleAccount)
        {
            return self.claudeSwapAccountSnapshots.map { account in
                // Provider-specific by design: claude-swap and tcr expose the same Claude account projection.
                let model = self.menuCardModel(for: .claude, context: ClaudeSwapAccountMenuDisplay.cardContext(
                    for: account,
                    planLabel: nil,
                    adapterError: self.claudeSwapLastError,
                    switchError: self.claudeSwapTransientState.lastErrorAccountID == account.id
                        ? self.claudeSwapTransientState.lastError : nil,
                    historySelection: self.claudeSwapPlanUtilizationHistorySelection(for: account)))
                return MergedOverviewRow(
                    provider: provider.instanceID,
                    accountID: account.id.source + ":" + account.id.opaqueID,
                    model: model)
            }
        }
        // Provider-specific by design: managed Codex accounts use the cached visible-account inventory.
        if provider == .codex,
           let projection = self.settings.codexVisibleAccountProjectionForMenuDisplay,
           projection.visibleAccounts.count > 1
        {
            let labels = CodexAccountSwitcherLabeling.labels(
                for: projection.visibleAccounts, hidePersonalInfo: self.settings.hidePersonalInfo)
            return projection.visibleAccounts.map { account in
                let record = self.codexAccountSnapshots.first {
                    $0.id == account.id && Self.codexPriorSnapshotAccountMatches($0.account, account: account)
                }
                var model = self.codexAccountMenuCardModel(for: account, accountSnapshot: record)
                if let label = labels[account.id] { model?.email = label }
                return MergedOverviewRow(provider: provider.instanceID, accountID: account.id, model: model)
            }
        }
        let accounts = self.settings.tokenAccounts(for: provider)
        guard accounts.count > 1, self.settings.effectiveSelectedTokenAccount(for: provider) != nil else { return [] }
        let cached = self.validTokenAccountSnapshots(provider: provider, accounts: accounts)
        return accounts.map { account in
            let record = cached.first { $0.id == account.id } ?? TokenAccountUsageSnapshot(
                account: account, snapshot: nil, error: nil, sourceLabel: nil, cacheKey: "")
            return MergedOverviewRow(
                provider: provider.instanceID,
                accountID: account.id.uuidString,
                model: self.tokenAccountMenuCardModel(for: provider, accountSnapshot: record))
        }
    }
}
