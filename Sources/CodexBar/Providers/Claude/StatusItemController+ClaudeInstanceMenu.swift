import AppKit
import CodexBarCore

extension StatusItemController {
    /// Renders claude-swap rows, else Claude instance cards, when either owns Claude account presentation.
    /// Returns false when neither applies and the caller should continue with token-account or ambient cards.
    func addClaudeAccountSourceMenuCards(
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext) -> Bool
    {
        if ClaudeSwapMenuPrecedence.prefersClaudeSwap(
            provider: context.currentProvider,
            accountCount: self.store.claudeSwapAccountSnapshots.count,
            showSingleAccount: self.settings.claudeSwapShowSingleAccount)
        {
            self.addClaudeSwapMenuCards(to: menu, captureMenu: captureMenu, context: context)
            return true
        }
        if ClaudeSwapMenuPrecedence.prefersClaudeInstances(
            provider: context.currentProvider,
            instancesOwnPresentation: self.store.claudeInstancesOwnAccountPresentation)
        {
            self.addClaudeInstanceMenuCards(to: menu, captureMenu: captureMenu, context: context)
            return true
        }
        return false
    }

    func addClaudeInstanceMenuCards(
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext)
    {
        let accounts = self.store.claudeInstanceAccountSnapshots
        if self.settings.multiAccountMenuLayout == .segmented, accounts.count > 1 {
            let selectedID = accounts.first { $0.id == self.claudeInstanceInspectedAccountID }?.id ?? accounts[0].id
            let item = NSMenuItem()
            // Instances have no source-owned active account; the switcher highlights the inspected instance.
            // Instance names are user-chosen labels, so they stay visible when personal info is hidden.
            item.view = ClaudeSwapAccountSwitcherView(
                display: ClaudeSwapAccountMenuDisplay(
                    accounts: accounts.map { Self.claudeInstanceSwitcherAccount($0, selectedID: selectedID) },
                    layout: .segmented,
                    switchingAccountID: nil,
                    errorAccountID: nil),
                hidePersonalInfo: false,
                width: context.menuWidth,
                onSelect: { [weak self, weak captureMenu] id in
                    self?.handleClaudeInstanceSelection(id, menu: captureMenu)
                })
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
            if let account = accounts.first(where: { $0.id == selectedID }) {
                self.addStackedClaudeInstanceMenuCards(accounts: [account], to: menu, context: context)
            }
            return
        }
        let plan = self.compactAccountPlan(for: .claude, accounts: accounts)
        guard plan.usesCompactLayout else {
            self.addStackedClaudeInstanceMenuCards(accounts: accounts, to: menu, context: context)
            return
        }
        self.addCompactAccountMenuRows(
            CompactAccountMenuRendering(
                plan: plan,
                accounts: accounts,
                idPrefix: "claudeInstance",
                cardModel: { [weak self] account in
                    self?.claudeInstanceCardModel(for: account)
                },
                planAction: nil),
            to: menu,
            captureMenu: captureMenu,
            context: context)
    }

    func handleClaudeInstanceSelection(_ id: ProviderAccountIdentity, menu: NSMenu?) {
        guard self.store.claudeInstanceAccountSnapshots.contains(where: { $0.id == id }) else { return }
        self.advanceMenuInteraction(for: menu)
        self.claudeInstanceInspectedAccountID = id
        self.invalidateMenus()
        if let menu {
            self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: .claude)
        }
    }

    private func addStackedClaudeInstanceMenuCards(
        accounts: [ProviderAccountUsageSnapshot],
        to menu: NSMenu,
        context: MenuCardContext)
    {
        self.addStackedMenuCards(
            accounts.compactMap { self.claudeInstanceCardModel(for: $0) },
            to: menu,
            context: context)
    }

    private func claudeInstanceCardModel(for account: ProviderAccountUsageSnapshot) -> UsageMenuCardView.Model? {
        let label = [account.displayLabel, account.accountEmail].compactMap(\.self).joined(separator: " · ")
        return self.menuCardModel(
            for: .claude,
            snapshotOverride: account.snapshot,
            errorOverride: account.error,
            forceOverrideCard: account.snapshot == nil,
            accountOverride: AccountInfo(email: label, plan: nil),
            sourceLabelOverride: ClaudeInstanceAccountProjection.sourceLabel)
    }

    private static func claudeInstanceSwitcherAccount(
        _ account: ProviderAccountUsageSnapshot,
        selectedID: ProviderAccountIdentity) -> ProviderAccountUsageSnapshot
    {
        ProviderAccountUsageSnapshot(
            id: account.id,
            provider: account.provider,
            displayLabel: account.displayLabel,
            accountEmail: account.accountEmail,
            isActive: account.id == selectedID,
            snapshot: account.snapshot,
            error: account.error,
            sourceLabel: account.sourceLabel)
    }
}
