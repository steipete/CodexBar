import AppKit
import CodexBarCore

enum ClaudeSwapMenuPrecedence {
    static func prefersClaudeSwap(provider: UsageProvider, accountCount: Int) -> Bool {
        provider == .claude && accountCount > 1
    }
}

extension StatusItemController {
    private static let defaultCodexAccountMenuProjectionRevalidationEnabled = !SettingsStore.isRunningTests

    #if DEBUG
    private static var codexAccountMenuProjectionRevalidationEnabledForTesting =
        defaultCodexAccountMenuProjectionRevalidationEnabled

    static func setCodexAccountMenuProjectionRevalidationEnabledForTesting(_ enabled: Bool) {
        self.codexAccountMenuProjectionRevalidationEnabledForTesting = enabled
    }

    static func resetCodexAccountMenuProjectionRevalidationEnabledForTesting() {
        self.codexAccountMenuProjectionRevalidationEnabledForTesting =
            self.defaultCodexAccountMenuProjectionRevalidationEnabled
    }
    #endif

    private static var codexAccountMenuProjectionRevalidationEnabled: Bool {
        #if DEBUG
        self.codexAccountMenuProjectionRevalidationEnabledForTesting
        #else
        self.defaultCodexAccountMenuProjectionRevalidationEnabled
        #endif
    }

    func tokenAccountMenuDisplay(for provider: UsageProvider) -> TokenAccountMenuDisplay? {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return nil }
        // Multiple claude-swap rows are the selected Claude account source, so do not mix them
        // with token-account cards or the segmented token-account switcher.
        if ClaudeSwapMenuPrecedence.prefersClaudeSwap(
            provider: provider,
            accountCount: self.store.claudeSwapAccountSnapshots.count)
        {
            return nil
        }
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
        guard let projection = self.settings.codexVisibleAccountProjectionForMenuDisplay else { return nil }
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

    func scheduleCodexAccountMenuProjectionRevalidationIfNeeded(for providers: [UsageProvider]) {
        guard Self.codexAccountMenuProjectionRevalidationEnabled else { return }
        guard providers.contains(.codex) else { return }
        guard self.settings.codexAccountMenuProjectionNeedsRevalidation else { return }
        guard self.codexAccountMenuProjectionRevalidationTask == nil else { return }

        self.codexAccountMenuProjectionRevalidationTask = Task { @MainActor [weak self] in
            guard let settings = self?.settings else { return }
            let result = await settings.revalidateCodexAccountMenuProjection()
            guard let self else { return }
            guard !Task.isCancelled else {
                self.codexAccountMenuProjectionRevalidationTask = nil
                return
            }
            self.codexAccountMenuProjectionRevalidationTask = nil

            switch result {
            case .updated:
                self.invalidateMenus(refreshOpenMenus: false)
            case .discarded, .skipped, .unchanged:
                break
            }
        }
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
