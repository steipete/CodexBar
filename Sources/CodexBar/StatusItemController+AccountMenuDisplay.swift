import AppKit
import CodexBarCore

extension StatusItemController {
    func tokenAccountMenuDisplay(for provider: UsageProvider) -> TokenAccountMenuDisplay? {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return nil }
        let accounts = self.settings.tokenAccounts(for: provider)
        guard accounts.count > 1 else { return nil }
        let activeIndex = self.settings.tokenAccountsData(for: provider)?.clampedActiveIndex() ?? 0
        let showAll = self.settings.multiAccountMenuLayout == .stacked
        let displayAccounts = showAll
            ? self.store.limitedTokenAccounts(accounts, selected: self.settings.selectedTokenAccount(for: provider))
            : accounts
        let snapshots = showAll
            ? self.tokenAccountSnapshots(for: provider, matching: displayAccounts)
            : []
        return TokenAccountMenuDisplay(
            provider: provider,
            accounts: displayAccounts,
            snapshots: snapshots,
            activeIndex: activeIndex,
            layout: showAll ? .stacked : .segmented)
    }

    private func tokenAccountSnapshots(
        for provider: UsageProvider,
        matching accounts: [ProviderTokenAccount]) -> [TokenAccountUsageSnapshot]
    {
        var snapshotsByID: [UUID: TokenAccountUsageSnapshot] = [:]
        for snapshot in self.store.accountSnapshots[provider] ?? [] {
            snapshotsByID[snapshot.account.id] = snapshot
        }
        return accounts.compactMap { snapshotsByID[$0.id] }
    }

    func codexAccountMenuDisplay(for provider: UsageProvider) -> CodexAccountMenuDisplay? {
        guard provider == .codex else { return nil }
        let projection = self.settings.codexVisibleAccountProjection
        guard projection.visibleAccounts.count > 1 else { return nil }
        let showAll = self.settings.multiAccountMenuLayout == .stacked
        let accounts = showAll
            ? self.store.limitedCodexVisibleAccounts(
                projection.visibleAccounts,
                snapshots: self.store.codexAccountSnapshots,
                activeVisibleAccountID: projection.activeVisibleAccountID)
            : projection.visibleAccounts
        let snapshots = showAll ? self.codexAccountSnapshots(matching: accounts) : []
        return CodexAccountMenuDisplay(
            accounts: accounts,
            snapshots: snapshots,
            activeVisibleAccountID: projection.activeVisibleAccountID,
            layout: showAll ? .stacked : .segmented)
    }

    private func codexAccountSnapshots(matching accounts: [CodexVisibleAccount]) -> [CodexAccountUsageSnapshot] {
        var snapshotsByID: [String: CodexAccountUsageSnapshot] = [:]
        for snapshot in self.store.codexAccountSnapshots {
            snapshotsByID[snapshot.id] = snapshot
        }
        return accounts.compactMap { snapshotsByID[$0.id] }
    }

    func stableCodexAccountMenuDisplay(
        _ display: CodexAccountMenuDisplay?,
        menu: NSMenu,
        provider: UsageProvider) -> CodexAccountMenuDisplay?
    {
        guard provider == .codex else { return display }
        guard display == nil else { return display }
        guard self.openMenus[ObjectIdentifier(menu)] != nil else { return display }
        guard menu.items.contains(where: { $0.view is CodexAccountSwitcherView }) else { return display }
        guard let previous = self.lastCodexAccountMenuDisplay, previous.showSwitcher else { return display }
        return previous
    }
}
