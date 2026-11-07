import AppKit
import CodexBarCore

extension StatusItemController {
    /// Hard cap on inline rows. NSMenu has no sticky footer, so a bounded list is what keeps Quit on screen.
    static let overviewInlineRowLimit = 12

    /// One level down, so a long all-accounts roster cannot push the footer off screen.
    func addOverviewOverflowItemIfNeeded(_ rows: [MergedOverviewRow], to menu: NSMenu, menuWidth: CGFloat) {
        guard rows.count > Self.overviewInlineRowLimit else { return }
        menu.addItem(self.makeOverviewOverflowItem(
            Array(rows.dropFirst(Self.overviewInlineRowLimit)),
            menuWidth: menuWidth))
    }

    func makeOverviewOverflowItem(_ rows: [MergedOverviewRow], menuWidth: CGFloat) -> NSMenuItem {
        let item = NSMenuItem(title: "\(L("More")) (\(rows.count))", action: nil, keyEquivalent: "")
        item.representedObject = "overviewOverflow"
        let submenu = NSMenu(title: item.title)
        submenu.autoenablesItems = false
        for row in rows {
            let plugin = UserProviderPluginRegistry.plugin(for: row.provider)
            // A plugin with no switcher tab has nowhere to navigate to, so its card shows here instead.
            if let plugin, !plugin.manifest.topLevel {
                submenu.addItem(self.makeUserPluginMenuCardItem(plugin, width: menuWidth))
                continue
            }
            let name = row.model?.providerName ?? plugin?.manifest.name ?? row.provider.rawValue
            let account = row.accountID == nil ? nil : row.model?.email
            let title = [name, account].compactMap(\.self).joined(separator: " · ")
            let child = NSMenuItem(title: title, action: #selector(self.selectOverviewProvider(_:)), keyEquivalent: "")
            child.target = self
            child.representedObject = "\(Self.overviewRowIdentifierPrefix)\(row.id)"
            submenu.addItem(child)
        }
        item.submenu = submenu
        return item
    }

    /// The detailed layout keeps share under its summary; compact moves it to the footer below.
    func addOverviewInlineShareItemIfDetailed(to menu: NSMenu, model: SpendDashboardModel) {
        guard self.settings.mergedOverviewLayout == .detailed,
              let share = self.makeOverviewShareStatsMenuItem(model: model)
        else { return }
        menu.addItem(share)
    }

    /// Closes the rows. Compact Overview's share action leads the footer, where it stays reachable below any list.
    func addOverviewRowsFooter(to menu: NSMenu, enabledProviders: [UsageProvider]) {
        menu.addItem(.separator())
        guard self.settings.mergedOverviewLayout == .compact else { return }
        let providers = self.overviewProviderScopes(enabledProviders: enabledProviders).spend
        guard self.overviewSpendSubscriptionCount(providers: providers) > 0,
              let share = self.makeOverviewShareStatsMenuItem(
                  model: self.overviewSpendDashboardModel(providers: providers))
        else { return }
        menu.addItem(share)
    }
}
