import AppKit
import CodexBarCore

/// A row's flyout. The type marks it as hosted, so reopening it never falls through to the root menu build.
final class OverviewProviderDetailMenu: NSMenu {
    /// Hydrated rows carry no chart ID, so reopening reads the provider from here to rebuild a stale card.
    var provider: UsageProvider?
}

extension StatusItemController {
    static let overviewProviderDetailID = "overviewProviderDetail"

    func makeOverviewRowSubmenu(
        provider: UsageProvider,
        model: UsageMenuCardView.Model,
        width: CGFloat) -> NSMenu?
    {
        if provider == .openai,
           self.settings.costSummaryShowsSubmenu(for: provider),
           let submenu = self.makeOpenAIAPIUsageSubmenu(provider: provider, width: width)
        {
            return submenu
        }
        // Mistral's top usage pane has no rate-limit bars of its own, so its Overview row prioritizes
        // cost history when the display style permits it. Other `tokenCostRequiresProviderSnapshot`
        // providers (e.g. opencodego) show real rate-limit bars and fall through to the generic check.
        if provider == .mistral,
           self.settings.costSummaryShowsSubmenu(for: provider),
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

    /// The row's flyout. It sits beside the menu, so opening it can never push the footer off screen.
    func makeOverviewLineSubmenu(provider: UsageProvider, width: CGFloat) -> NSMenu {
        let submenu = OverviewProviderDetailMenu()
        submenu.provider = provider
        submenu.autoenablesItems = false
        submenu.minimumWidth = width
        submenu.delegate = self
        let placeholder = NSMenuItem()
        placeholder.isEnabled = true
        placeholder.representedObject = Self.overviewProviderDetailID
        placeholder.toolTip = provider.rawValue
        submenu.addItem(placeholder)
        return submenu
    }

    /// Everything the row summarizes: each limit, pace, plan, account, spend and full error. Charts go one level
    /// deeper.
    func appendOverviewProviderDetail(to menu: NSMenu, provider: UsageProvider, width: CGFloat) -> Bool {
        let model = self.store.menuCardModel(for: provider)
        let card = self.makeMenuCardItem(
            OverviewMenuCardRowView(
                model: model,
                storageText: self.store.storageFootprintText(for: provider),
                width: width,
                showsFullCard: true),
            id: "overviewProviderDetail-\(provider.rawValue)",
            width: width,
            containsInteractiveControls: model.containsInteractiveControls)
        // The menu's type identifies it; a chart ID here would rebuild it as that chart.
        card.representedObject = nil
        menu.addItem(card)
        menu.addItem(.separator())
        if let chart = self.makeOverviewRowSubmenu(provider: provider, model: model, width: width) {
            let title = Self.overviewDetailChartTitle(chart)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = chart
            menu.addItem(item)
        }
        let open = NSMenuItem(
            title: L("Show details"),
            action: #selector(self.selectOverviewProvider(_:)),
            keyEquivalent: "")
        open.target = self
        open.representedObject = "\(Self.overviewRowIdentifierPrefix)\(provider.rawValue)"
        menu.addItem(open)
        return true
    }

    private static func overviewDetailChartTitle(_ chart: NSMenu) -> String {
        switch chart.items.first?.representedObject as? String {
        case self.usageHistoryChartID: L("Plan Usage")
        case self.storageBreakdownID: L("Storage")
        default: L("Cost")
        }
    }

    @objc func selectOverviewProvider(_ sender: NSMenuItem) {
        guard let represented = sender.representedObject as? String,
              represented.hasPrefix(Self.overviewRowIdentifierPrefix)
        else {
            return
        }
        let rawProvider = String(represented.dropFirst(Self.overviewRowIdentifierPrefix.count))
        // A rebuild can detach a clicked flyout item before AppKit sends its action, leaving it without a menu.
        guard let provider = MergedOverviewRow.providerID(from: rawProvider),
              let menu = sender.menu?.supermenu ?? sender.menu ?? self.mergedMenu
        else {
            return
        }

        self.selectOverviewProvider(provider, menu: menu)
    }

    func selectOverviewProvider(_ provider: ProviderInstanceID, menu: NSMenu) {
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
        self.requestProviderSwitcherMenuRebuild(menu, provider: provider.firstPartyProvider)
    }
}
