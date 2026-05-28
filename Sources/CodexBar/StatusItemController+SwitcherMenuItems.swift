import AppKit
import CodexBarCore

extension StatusItemController {
    func makeProviderSwitcherItem(
        providers: [UsageProvider],
        includesOverview: Bool,
        selected: ProviderSwitcherSelection,
        menu: NSMenu,
        width: CGFloat) -> NSMenuItem
    {
        let view = ProviderSwitcherView(
            providers: providers,
            selected: selected,
            includesOverview: includesOverview,
            width: width,
            showsIcons: self.settings.switcherShowsIcons,
            iconProvider: { [weak self] provider in
                self?.switcherIcon(for: provider) ?? NSImage()
            },
            weeklyRemainingProvider: { [weak self] provider in
                self?.switcherWeeklyRemaining(for: provider)
            },
            onSelect: { [weak self, weak menu] selection in
                guard let self, let menu else { return }
                self.noteProviderSwitcherInteraction()
                if selection == self.lastMergedSwitcherSelection {
                    self.menuLogger.debug(
                        "provider switch selection ignored",
                        metadata: ["selection": selection.logValue])
                    return
                }
                let settingsSuppressionToken = self.beginProviderSwitcherSettingsSuppression()
                let provider: UsageProvider?
                switch selection {
                case .overview:
                    self.settings.mergedMenuLastSelectedWasOverview = true
                    provider = self.resolvedMenuProvider()
                case let .provider(selectedProvider):
                    self.settings.mergedMenuLastSelectedWasOverview = false
                    self.selectedMenuProvider = selectedProvider
                    provider = selectedProvider
                }
                switch selection {
                case .overview:
                    self.lastMenuProvider = provider ?? .codex
                case let .provider(provider):
                    self.lastMenuProvider = provider
                }
                self.lastMergedSwitcherSelection = selection
                self.deferSwitcherMenuRebuildIfStillVisible(
                    menu,
                    provider: provider,
                    settingsSuppressionToken: settingsSuppressionToken)
            })
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }

    func makeTokenAccountSwitcherItem(
        display: TokenAccountMenuDisplay,
        menu: NSMenu,
        width: CGFloat) -> NSMenuItem
    {
        let view = TokenAccountSwitcherView(
            accounts: display.accounts,
            selectedIndex: display.activeIndex,
            width: width,
            onSelect: { [weak self, weak menu] index -> Task<Void, Never>? in
                guard let self, let menu else { return nil }
                self.noteProviderSwitcherInteraction()
                self.settings.setActiveTokenAccountIndex(index, for: display.provider)
                self.applyIcon(phase: nil)
                self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: display.provider)
                return Task { @MainActor [weak self, weak menu] in
                    guard let self else { return }
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await self.store.refreshProvider(display.provider)
                    }
                    guard let menu else { return }
                    self.refreshOpenMenuIfStillVisible(menu, provider: display.provider)
                }
            })
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }

    func makeCodexAccountSwitcherItem(
        display: CodexAccountMenuDisplay,
        menu: NSMenu,
        width: CGFloat) -> NSMenuItem
    {
        let view = CodexAccountSwitcherView(
            accounts: display.accounts,
            selectedAccountID: display.activeVisibleAccountID,
            width: width,
            onSelect: { [weak self, weak menu] account in
                guard let self else { return }
                self.handleCodexVisibleAccountSelection(account, menu: menu)
            })
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }

    @discardableResult
    private func handleCodexVisibleAccountSelection(_ account: CodexVisibleAccount, menu: NSMenu?) -> Bool {
        let visibleAccountID = account.id
        self.noteProviderSwitcherInteraction()
        self.codexAccountSelectionRefreshGeneration &+= 1
        let generation = self.codexAccountSelectionRefreshGeneration
        self.codexAccountSelectionRefreshTask?.cancel()
        self.settings.selectDisplayedCodexVisibleAccount(account)
        if self.store.prepareCodexAccountScopedRefreshIfNeeded(), let menu {
            self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: .codex)
        }
        self.codexAccountSelectionRefreshTask = Task { @MainActor [weak self, weak menu] in
            guard let self else { return }
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await self.store.refreshCodexAccountScopedState(
                    allowDisabled: true,
                    phaseDidChange: { [weak self, weak menu] _ in
                        guard let self, let menu else { return }
                        guard self.codexAccountSelectionRefreshGeneration == generation else { return }
                        guard self.settings.codexVisibleAccountProjection.activeVisibleAccountID == visibleAccountID
                        else {
                            return
                        }
                        self.refreshOpenMenuIfStillVisible(menu, provider: .codex)
                    })
            }
            if self.codexAccountSelectionRefreshGeneration == generation {
                self.codexAccountSelectionRefreshTask = nil
            }
        }
        return true
    }
}
