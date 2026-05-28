import AppKit
import CodexBarCore

extension StatusItemController {
    struct MenuPopulationCompatibility {
        let canSmartUpdate: Bool
        let canPreserveProviderSwitcher: Bool
        let providerSwitcherWidthMatches: Bool
    }

    struct MenuPopulationInput {
        let menu: NSMenu
        let enabledProviders: [UsageProvider]
        let includesOverview: Bool
        let switcherSelection: ProviderSwitcherSelection?
        let codexAccountDisplay: CodexAccountMenuDisplay?
        let tokenAccountDisplay: TokenAccountMenuDisplay?
        let menuWidth: CGFloat
        let isOverviewSelected: Bool
    }

    func menuPopulationCompatibility(_ input: MenuPopulationInput) -> MenuPopulationCompatibility {
        let hasTokenSwitcher = input.menu.items.contains { $0.view is TokenAccountSwitcherView }
        let hasCodexSwitcher = input.menu.items.contains { $0.view is CodexAccountSwitcherView }
        let switcherProvidersMatch = input.enabledProviders == self.lastSwitcherProviders
        let switcherUsageBarsShowUsedMatch = self.settings.usageBarsShowUsed == self.lastSwitcherUsageBarsShowUsed
        let switcherSelectionMatches = input.switcherSelection == self.lastMergedSwitcherSelection
        let switcherOverviewAvailabilityMatches = input.includesOverview == self.lastSwitcherIncludesOverview
        let tokenSwitcherCompatible = input.tokenAccountDisplay == self.lastTokenAccountMenuDisplay &&
            ((input.tokenAccountDisplay?.showSwitcher == true && hasTokenSwitcher) ||
                (input.tokenAccountDisplay?.showSwitcher != true && !hasTokenSwitcher))
        let codexSwitcherCompatible = input.codexAccountDisplay == self.lastCodexAccountMenuDisplay &&
            ((input.codexAccountDisplay?.showSwitcher == true && hasCodexSwitcher) ||
                (input.codexAccountDisplay?.showSwitcher != true && !hasCodexSwitcher))
        let reusableRowWidthsMatch = self.reusableFixedWidthRows(in: input.menu).allSatisfy { item in
            guard let view = item.view else { return false }
            return abs(view.frame.width - input.menuWidth) <= 0.5
        }
        let providerSwitcherWidthMatches = (input.menu.items.first?.view as? ProviderSwitcherView).map { view in
            abs(view.frame.width - input.menuWidth) <= 0.5
        } ?? false

        let canSmartUpdate = self.shouldMergeIcons &&
            input.enabledProviders.count > 1 &&
            !input.isOverviewSelected &&
            switcherProvidersMatch &&
            switcherUsageBarsShowUsedMatch &&
            switcherSelectionMatches &&
            switcherOverviewAvailabilityMatches &&
            tokenSwitcherCompatible &&
            codexSwitcherCompatible &&
            reusableRowWidthsMatch &&
            !input.menu.items.isEmpty &&
            input.menu.items.first?.view is ProviderSwitcherView

        let canPreserveProviderSwitcher = self.shouldMergeIcons &&
            input.enabledProviders.count > 1 &&
            switcherProvidersMatch &&
            switcherUsageBarsShowUsedMatch &&
            switcherOverviewAvailabilityMatches &&
            providerSwitcherWidthMatches &&
            !input.menu.items.isEmpty &&
            input.menu.items.first?.view is ProviderSwitcherView

        return MenuPopulationCompatibility(
            canSmartUpdate: canSmartUpdate,
            canPreserveProviderSwitcher: canPreserveProviderSwitcher,
            providerSwitcherWidthMatches: providerSwitcherWidthMatches)
    }

    func reusableFixedWidthRows(in menu: NSMenu) -> [NSMenuItem] {
        guard !menu.items.isEmpty else { return [] }

        var reusableRows: [NSMenuItem] = []
        var index = self.providerSwitcherContentStartIndex(in: menu)
        if index > 0 {
            reusableRows.append(menu.items[0])
        }
        if menu.items.count > index,
           menu.items[index].view is CodexAccountSwitcherView
        {
            reusableRows.append(menu.items[index])
            index += 2
        }
        if menu.items.count > index,
           menu.items[index].view is TokenAccountSwitcherView
        {
            reusableRows.append(menu.items[index])
        }
        return reusableRows
    }
}
