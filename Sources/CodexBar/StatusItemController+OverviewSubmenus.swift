import AppKit
import CodexBarCore

extension StatusItemController {
    func makeOverviewRowSubmenu(
        provider: UsageProvider,
        model: UsageMenuCardView.Model,
        width: CGFloat) -> NSMenu?
    {
        if provider == .openai,
           let submenu = self.makeOpenAIAPIUsageSubmenu(provider: provider, width: width)
        {
            return submenu
        }
        if provider == .zai,
           let submenu = self.makeZaiUsageDetailsSubmenu(snapshot: self.store.snapshot(for: provider))
        {
            return submenu
        }
        // Mistral's top usage pane has no rate-limit bars of its own, so its Overview row always
        // prioritizes cost history too. Other `tokenCostRequiresProviderSnapshot` providers (e.g.
        // opencodego) show real rate-limit bars and should fall through to the settings-gated
        // check below, same as Codex/Claude (see StatusItemController+Menu.swift's makeUsageSubmenu).
        if provider == .mistral,
           let submenu = self.makeCostHistorySubmenu(provider: provider, width: width)
        {
            return submenu
        }
        if self.settings.costSummaryShowsSubmenu(for: provider),
           model.tokenUsage != nil,
           let submenu = self.makeCostHistorySubmenu(provider: provider, width: width)
        {
            return submenu
        }
        if let submenu = self.makeUsageHistorySubmenu(provider: provider, width: width) {
            return submenu
        }
        return self.makeStorageBreakdownSubmenu(provider: provider, width: width)
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
        self.preservingMergedSwitcherContentCachesDuringInvalidation {
            self.settings.mergedMenuLastSelectedWasOverview = false
            self.lastMergedSwitcherSelection = .provider(provider)
            self.selectedMenuProvider = provider
            self.lastMenuProvider = provider
            self.refreshProviderSelectionDependentUI(deferRendering: true)
        }
        // Custom-view clicks stay open and rebuild next turn. Standard menu-item activation can close;
        // menuWillOpen then renders the saved provider without doing structural work inside the action.
        self.requestProviderSwitcherMenuRebuild(menu, provider: provider)
    }
}
