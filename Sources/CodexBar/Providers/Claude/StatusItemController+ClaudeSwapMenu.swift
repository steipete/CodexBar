import AppKit
import CodexBarCore

extension StatusItemController {
    func addClaudeSwapMenuCards(
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext)
    {
        self.discardStaleClaudeSwapViewSelection()
        let accounts = self.store.claudeSwapAccountSnapshots
        let display = ClaudeSwapAccountMenuDisplay(
            accounts: accounts,
            layout: self.settings.multiAccountMenuLayout,
            switchingAccountID: self.store.claudeSwapTransientState.switchingAccountID,
            errorAccountID: self.store.claudeSwapTransientState.lastErrorAccountID,
            viewedAccountID: self.claudeSwapViewedAccountID)
        if display.showsSwitcher {
            let item = NSMenuItem()
            item.view = ClaudeSwapAccountMenuDisplay.switcherView(
                display: display,
                hidePersonalInfo: self.settings.hidePersonalInfo,
                width: context.menuWidth,
                onSelect: { [weak self, weak captureMenu] id in
                    self?.handleClaudeSwapAccountSelection(id, menu: captureMenu)
                })
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
            if !accounts.contains(where: \.isActive) {
                let notice = NSMenuItem(title: L("No active account"), action: nil, keyEquivalent: "")
                notice.isEnabled = false
                menu.addItem(notice)
            }
            // No "Details for <account>" heading: the switcher highlights the viewed segment, so a
            // heading would only restate it. VoiceOver still gets the state from the segment's own
            // accessibility label.
            if let account = display.displayedAccount {
                self.addStackedClaudeSwapMenuCards(
                    accounts: [account],
                    to: menu,
                    captureMenu: captureMenu,
                    context: context)
            } else if self.addStorageMenuCardSection(to: menu, provider: .claude, width: context.menuWidth) {
                menu.addItem(.separator())
            }
            return
        }
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
                    self?.claudeSwapAccountRepairAction(account, menu: captureMenu)
                }),
            to: menu,
            captureMenu: captureMenu,
            context: context)
    }

    /// The account the segmented menu should show, or nil when the recorded selection belongs to a
    /// configuration that is no longer current.
    var claudeSwapViewedAccountID: ProviderAccountIdentity? {
        guard let selection = self.claudeSwapViewSelection,
              selection.configurationKey == self.store.claudeSwapConfigurationKey
        else { return nil }
        return selection.accountID
    }

    /// Drops a view selection made under a superseded adapter configuration (adapter disabled or a
    /// different executable). The stale selection never survives as hidden state.
    func discardStaleClaudeSwapViewSelection() {
        guard self.claudeSwapViewSelection != nil, self.claudeSwapViewedAccountID == nil else { return }
        self.claudeSwapViewSelection = nil
    }

    /// View-only account selection. Clicking a segment changes which account's details the menu
    /// renders and never asks claude-swap to activate that slot; activation stays behind the shared
    /// "System Account" submenu. Unavailable accounts stay selectable for inspection, and a
    /// selection made during a pending or failed switch takes precedence over that activation state.
    func handleClaudeSwapAccountSelection(_ id: ProviderAccountIdentity, menu: NSMenu?) {
        guard self.store.claudeSwapAccountSnapshots.contains(where: { $0.id == id }) else { return }
        self.advanceMenuInteraction(for: menu)
        let selection = ClaudeSwapViewSelection(
            configurationKey: self.store.claudeSwapConfigurationKey,
            accountID: id)
        if self.claudeSwapViewSelection != selection {
            self.claudeSwapViewSelection = selection
            self.invalidateMenus()
        }
        if let menu {
            self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: .claude)
        }
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
                return self?.claudeSwapAccountRepairAction(cardRows[index].account, menu: captureMenu)
            })
    }

    func claudeSwapCardModel(for account: ProviderAccountUsageSnapshot) -> UsageMenuCardView.Model? {
        let model = self.menuCardModel(
            for: .claude,
            context: ClaudeSwapAccountMenuDisplay.cardContext(
                for: account,
                planLabel: self.claudeSwapAccountActionLabel(account),
                adapterError: self.store.claudeSwapLastError,
                switchError: self.store.claudeSwapTransientState.lastErrorAccountID == account.id
                    ? self.store.claudeSwapTransientState.lastError
                    : nil))
        // The switch error stays in the store and renders through the card error above, so System account feedback
        // only adds progress and success, and never hides an error the card already shows.
        let switchFeedback = self.systemAccountSwitchFeedback
            .subtitle(for: .claude, accountID: account.id.opaqueID)
            .flatMap { $0.style == .error ? nil : $0 }
        return model?.applyingSwitchFeedback(switchFeedback)
    }

    /// Card badge and repair label: "Active", "Re-authenticate" or "Loading…". Switching lives in the System Account
    /// submenu.
    func claudeSwapAccountActionLabel(_ account: ProviderAccountUsageSnapshot) -> String? {
        ClaudeSwapAccountMenuDisplay.actionLabel(
            for: account,
            switchingAccountID: self.store.claudeSwapTransientState.switchingAccountID,
            switchInFlight: self.store.claudeSwapTransientState.task != nil)
    }

    /// The card's only activation action: explicit repair of the active slot. Switching to another account lives in
    /// the System Account submenu.
    func claudeSwapAccountRepairAction(
        _ account: ProviderAccountUsageSnapshot,
        menu: NSMenu)
        -> (() -> Void)?
    {
        guard self.store.claudeSwapTransientState.task == nil, account.isActive, account.canActivate else { return nil }
        let accountID = account.id
        return { [weak self, weak menu] in
            guard let self else { return }
            self.advanceMenuInteraction(for: menu)
            self.store.switchClaudeSwapAccount(accountID)
        }
    }
}
