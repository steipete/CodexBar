import AppKit
import CodexBarCore

enum GrokAccountMenuSupport {
    static func suppressesTokenAccounts(provider: UsageProvider, visibleAccountCount: Int) -> Bool {
        provider == .grok && visibleAccountCount > 1
    }
}

extension StatusItemController {
    func grokAccountMenuDisplay(for provider: UsageProvider) -> GrokAccountMenuDisplay? {
        guard provider == .grok else { return nil }
        let projection = self.settings.grokVisibleAccountProjection
        guard projection.visibleAccounts.count > 1 else { return nil }
        let showAll = self.settings.multiAccountMenuLayout == .stacked
        let snapshotsByID = Dictionary(uniqueKeysWithValues: self.store.grokAccountSnapshots.map { ($0.id, $0) })
        let snapshots = showAll ? projection.visibleAccounts.compactMap { snapshotsByID[$0.id] } : []
        return GrokAccountMenuDisplay(
            accounts: projection.visibleAccounts,
            snapshots: snapshots,
            activeVisibleAccountID: projection.activeVisibleAccountID,
            layout: showAll ? .stacked : .segmented)
    }

    func addGrokAccountSwitcherIfNeeded(
        to menu: NSMenu,
        display: GrokAccountMenuDisplay?,
        width: CGFloat,
        captureMenu: NSMenu? = nil)
    {
        guard let display, display.showSwitcher else { return }
        let switcherItem = self.makeGrokAccountSwitcherItem(
            display: display,
            menu: captureMenu ?? menu,
            width: width)
        menu.addItem(switcherItem)
        menu.addItem(.separator())
    }

    func addGrokAccountMenuCards(
        _ display: GrokAccountMenuDisplay,
        to menu: NSMenu,
        context: MenuCardContext)
    {
        let snapshotsByID = Dictionary(uniqueKeysWithValues: display.snapshots.map { ($0.id, $0) })
        let cards = display.accounts.compactMap { account -> UsageMenuCardView.Model? in
            let accountSnapshot = snapshotsByID[account.id]
            return self.menuCardModel(
                for: .grok,
                context: .account(.init(
                    snapshot: accountSnapshot?.snapshot,
                    error: accountSnapshot?.error,
                    info: AccountInfo(email: account.email, plan: nil))))
        }
        if cards.isEmpty, let model = self.menuCardModel(for: context.selectedProvider) {
            self.addStackedMenuCards([model], to: menu, context: context)
            return
        }
        self.addStackedMenuCards(cards, to: menu, context: context)
    }

    private func makeGrokAccountSwitcherItem(
        display: GrokAccountMenuDisplay,
        menu: NSMenu,
        width: CGFloat) -> NSMenuItem
    {
        let view = GrokAccountSwitcherView(
            accounts: display.accounts,
            selectedAccountID: display.activeVisibleAccountID,
            width: width,
            hidePersonalInfo: self.settings.hidePersonalInfo,
            onSelect: { [weak self, weak menu] account in
                guard let self else { return }
                self.handleGrokVisibleAccountSelection(account, menu: menu)
            })
        let item = NSMenuItem()
        item.title = ""
        item.view = view
        item.isEnabled = false
        return item
    }

    @discardableResult
    private func handleGrokVisibleAccountSelection(_ account: GrokVisibleAccount, menu: NSMenu?) -> Bool {
        self.advanceMenuInteraction(for: menu)
        _ = self.settings.selectGrokVisibleAccount(id: account.id)
        self.store.activateCachedGrokAccountSnapshot(visibleAccountID: account.id)
        self.applyIcon(phase: nil)
        if let menu {
            self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: .grok)
        }
        Task { @MainActor [weak self, weak menu] in
            guard let self else { return }
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await self.store.refreshProvider(.grok)
            }
            guard let menu else { return }
            self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: .grok)
        }
        return true
    }
}
