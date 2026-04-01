import AppKit
import CodexBarCore
import Foundation

struct CodexAccountMenuDisplay {
    let accounts: [CodexVisibleAccount]
    let cachedSnapshots: [String: CodexVisibleAccountUsageSnapshot]
    let activeVisibleAccountID: String?
    let displayMode: CodexMenuDisplayMode

    var showAll: Bool {
        self.displayMode == .all
    }

    var showSwitcher: Bool {
        !self.showAll && self.accounts.count > 1
    }

    var showSortControl: Bool {
        self.showAll && self.accounts.count > 1
    }
}

extension StatusItemController {
    func addCodexMenuControlsIfNeeded(to menu: NSMenu, display: CodexAccountMenuDisplay?) {
        self.addCodexMenuDisplayModeToggleIfNeeded(to: menu, display: display)
        self.addCodexControlSpacerIfNeeded(to: menu, display: display)
        self.addCodexAccountSwitcherIfNeeded(to: menu, display: display)
        self.addCodexSortControlIfNeeded(to: menu, display: display)
    }

    func addCodexMenuDisplayModeToggleIfNeeded(to menu: NSMenu, display: CodexAccountMenuDisplay?) {
        guard let display,
              self.settings.shouldShowCodexMenuDisplayModeToggle(for: .codex)
        else {
            return
        }
        let item = self.makeCodexMenuDisplayModeToggleItem(display: display, menu: menu)
        menu.addItem(item)
    }

    func addCodexControlSpacerIfNeeded(to menu: NSMenu, display: CodexAccountMenuDisplay?) {
        guard let display, display.showSwitcher else { return }
        menu.addItem(self.makeCodexControlSpacerItem(menu: menu))
    }

    func addCodexAccountSwitcherIfNeeded(to menu: NSMenu, display: CodexAccountMenuDisplay?) {
        guard let display, display.showSwitcher else { return }
        let switcherItem = self.makeCodexAccountSwitcherItem(display: display, menu: menu)
        menu.addItem(switcherItem)
    }

    func addCodexSortControlIfNeeded(to menu: NSMenu, display: CodexAccountMenuDisplay?) {
        guard let display, display.showSortControl,
              self.settings.shouldShowCodexMenuSortControl(for: .codex)
        else {
            return
        }
        menu.addItem(self.makeCodexSortControlItem(menu: menu))
    }

    func codexAccountMenuDisplay(for provider: UsageProvider) -> CodexAccountMenuDisplay? {
        guard provider == .codex else { return nil }
        let projection = self.settings.codexVisibleAccountProjection
        guard projection.visibleAccounts.count > 1 else { return nil }
        let cachedSnapshots = Dictionary(
            uniqueKeysWithValues: projection.visibleAccounts.compactMap { account in
                self.store.codexAllAccountsSnapshotCache[account.id].map { (account.id, $0) }
            })
        return CodexAccountMenuDisplay(
            accounts: projection.visibleAccounts,
            cachedSnapshots: cachedSnapshots,
            activeVisibleAccountID: projection.activeVisibleAccountID,
            displayMode: self.settings.codexMenuDisplayMode)
    }

    func shouldRefreshCodexAllAccountsOnMenuOpen(_ menu: NSMenu) -> Bool {
        guard self.menuProvider(for: menu) == .codex else { return false }
        guard self.settings.codexMenuDisplayMode == .all else { return false }
        return self.settings.codexVisibleAccountProjection.visibleAccounts.count > 1
    }

    func refreshCodexAllAccountsMenuIfNeeded(_ menu: NSMenu) {
        self.store.refreshCodexAllAccountsMenuState(
            selectedDidUpdate: { [weak self, weak menu] in
                guard let self, let menu else { return }
                self.refreshOpenMenuIfStillVisible(menu, provider: .codex)
            },
            didFinish: { [weak self, weak menu] in
                guard let self, let menu else { return }
                self.refreshOpenMenuIfStillVisible(menu, provider: .codex)
            })
    }

    private func makeCodexMenuDisplayModeToggleItem(
        display: CodexAccountMenuDisplay,
        menu: NSMenu) -> NSMenuItem
    {
        let view = CodexMenuDisplayModeToggleView(
            selectedMode: display.displayMode,
            width: self.menuCardWidth(for: self.store.enabledProvidersForDisplay(), menu: menu),
            onSelect: { [weak self, weak menu] mode in
                guard let self, let menu else { return }
                guard self.settings.codexMenuDisplayMode != mode else { return }
                self.settings.codexMenuDisplayMode = mode
                self.populateMenu(menu, provider: .codex)
                self.markMenuFresh(menu)
                self.applyIcon(phase: nil)
                if mode == .all {
                    self.refreshCodexAllAccountsMenuIfNeeded(menu)
                }
            })
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }

    private func makeCodexAccountSwitcherItem(
        display: CodexAccountMenuDisplay,
        menu: NSMenu) -> NSMenuItem
    {
        let view = CodexAccountSwitcherView(
            accounts: display.accounts,
            selectedAccountID: display.activeVisibleAccountID,
            width: self.menuCardWidth(for: self.store.enabledProvidersForDisplay(), menu: menu),
            onSelect: { [weak self, weak menu] visibleAccountID in
                guard let self else { return }
                self.handleCodexVisibleAccountSelection(visibleAccountID, menu: menu)
            })
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }

    private func makeCodexControlSpacerItem(menu: NSMenu) -> NSMenuItem {
        let width = self.menuCardWidth(for: self.store.enabledProvidersForDisplay(), menu: menu)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 5))
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }

    @discardableResult
    private func handleCodexVisibleAccountSelection(_ visibleAccountID: String, menu: NSMenu?) -> Bool {
        guard self.settings.selectCodexVisibleAccount(id: visibleAccountID) else { return false }
        let didInvalidate = self.store.prepareCodexAccountScopedRefreshIfNeeded()
        let didApplyCached = self.store.applyCachedCodexVisibleAccountSnapshotIfAvailable(
            visibleAccountID: visibleAccountID)
        if didInvalidate || didApplyCached, let menu {
            self.refreshOpenMenuIfStillVisible(menu, provider: .codex)
        }
        Task { @MainActor in
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await self.store.refreshCodexAccountScopedState(
                    allowDisabled: true,
                    phaseDidChange: { [weak self, weak menu] _ in
                        guard let self, let menu else { return }
                        guard self.settings.codexVisibleAccountProjection.activeVisibleAccountID == visibleAccountID
                        else {
                            return
                        }
                        self.refreshOpenMenuIfStillVisible(menu, provider: .codex)
                    })
            }
        }
        return true
    }
}
