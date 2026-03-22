import AppKit
import CodexBarCore

extension StatusItemController {
    @discardableResult
    func addOverviewRows(
        to menu: NSMenu,
        enabledProviders: [UsageProvider],
        menuWidth: CGFloat) -> Bool
    {
        let overviewProviders = self.settings.reconcileMergedOverviewSelectedProviders(
            activeProviders: enabledProviders)
        let rows: [(provider: UsageProvider, model: UsageMenuCardView.Model)] = overviewProviders
            .compactMap { provider in
                guard let model = self.menuCardModel(for: provider) else { return nil }
                return (provider: provider, model: model)
            }
        guard !rows.isEmpty else { return false }

        for (index, row) in rows.enumerated() {
            let identifier = "\(Self.overviewRowIdentifierPrefix)\(row.provider.rawValue)"
            let item = self.makeMenuCardItem(
                OverviewMenuCardRowView(model: row.model, width: menuWidth),
                id: identifier,
                width: menuWidth,
                onClick: { [weak self, weak menu] in
                    guard let self, let menu else { return }
                    self.selectOverviewProvider(row.provider, menu: menu)
                })
            item.target = self
            item.action = #selector(self.selectOverviewProvider(_:))
            menu.addItem(item)
            if index < rows.count - 1 {
                menu.addItem(.separator())
            }
        }
        return true
    }

    func addOverviewEmptyState(to menu: NSMenu, enabledProviders: [UsageProvider]) {
        let resolvedProviders = self.settings.resolvedMergedOverviewProviders(
            activeProviders: enabledProviders,
            maxVisibleProviders: Self.maxOverviewProviders)
        let message = if resolvedProviders.isEmpty {
            "No providers selected for Overview."
        } else {
            "No overview data available."
        }
        let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.representedObject = "overviewEmptyState"
        menu.addItem(item)
    }

    func includesOverviewTab(enabledProviders: [UsageProvider]) -> Bool {
        !self.settings.resolvedMergedOverviewProviders(
            activeProviders: enabledProviders,
            maxVisibleProviders: Self.maxOverviewProviders).isEmpty
    }

    func resolvedSwitcherSelection(
        enabledProviders: [UsageProvider],
        includesOverview: Bool) -> ProviderSwitcherSelection
    {
        if includesOverview, self.settings.mergedMenuLastSelectedWasOverview {
            return .overview
        }
        return .provider(self.resolvedMenuProvider(enabledProviders: enabledProviders) ?? .codex)
    }

    @objc func selectOverviewProvider(_ sender: NSMenuItem) {
        guard let represented = sender.representedObject as? String,
              represented.hasPrefix(Self.overviewRowIdentifierPrefix)
        else {
            return
        }
        let rawProvider = String(represented.dropFirst(Self.overviewRowIdentifierPrefix.count))
        guard let provider = UsageProvider(rawValue: rawProvider),
              let menu = sender.menu
        else {
            return
        }

        self.selectOverviewProvider(provider, menu: menu)
    }

    func selectOverviewProvider(_ provider: UsageProvider, menu: NSMenu) {
        if !self.settings.mergedMenuLastSelectedWasOverview, self.selectedMenuProvider == provider { return }
        self.settings.mergedMenuLastSelectedWasOverview = false
        self.lastMergedSwitcherSelection = nil
        self.selectedMenuProvider = provider
        self.lastMenuProvider = provider
        self.populateMenu(menu, provider: provider)
        self.markMenuFresh(menu)
        self.applyIcon(phase: nil)
    }
}
