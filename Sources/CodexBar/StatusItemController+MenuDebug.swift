import AppKit
import CodexBarCore

extension StatusItemController {
    private struct MenuStructureSummary {
        let itemCount: Int
        var viewBackedItems = 0
        var menuCardItems = 0
        var switcherItems = 0
        var submenuItems = 0
        var chartSubviewMenus = 0
        var totalViews = 0
        var hostingViews = 0
        var buttonViews = 0
        var layerBackedViews = 0
    }

    func logOpenMenuStructure(_ menu: NSMenu, provider: UsageProvider?) {
        Task { @MainActor [weak self, weak menu] in
            guard let self, let menu else { return }
            await Task.yield()
            guard self.openMenus[ObjectIdentifier(menu)] != nil else { return }
            let summary = self.menuStructureSummary(for: menu)
            AgentDebugLogger.log(
                "0.20 top-level menu structure",
                hypothesisId: "Q",
                location: "StatusItemController+MenuDebug.swift:logOpenMenuStructure",
                data: [
                    "provider": provider?.rawValue ?? "overview",
                    "itemCount": String(summary.itemCount),
                    "viewBackedItems": String(summary.viewBackedItems),
                    "menuCardItems": String(summary.menuCardItems),
                    "switcherItems": String(summary.switcherItems),
                    "submenuItems": String(summary.submenuItems),
                    "chartSubviewMenus": String(summary.chartSubviewMenus),
                    "totalViews": String(summary.totalViews),
                    "hostingViews": String(summary.hostingViews),
                    "buttonViews": String(summary.buttonViews),
                    "layerBackedViews": String(summary.layerBackedViews),
                    "storeRefreshing": self.store.isRefreshing ? "1" : "0",
                ])
        }
    }

    private func menuStructureSummary(for menu: NSMenu) -> MenuStructureSummary {
        var summary = MenuStructureSummary(itemCount: menu.items.count)
        for item in menu.items {
            if let represented = item.representedObject as? String,
               represented.hasPrefix("menuCard")
            {
                summary.menuCardItems += 1
            }
            if item.view != nil {
                summary.viewBackedItems += 1
            }
            if item.view is ProviderSwitcherView ||
                item.view is TokenAccountSwitcherView ||
                item.view is CodexAccountSwitcherView
            {
                summary.switcherItems += 1
            }
            if let submenu = item.submenu {
                summary.submenuItems += 1
                if self.isChartSubviewMenu(submenu) {
                    summary.chartSubviewMenus += 1
                }
            }
            if let view = item.view {
                self.accumulateMenuViewSummary(from: view, into: &summary)
            }
        }
        return summary
    }

    private func accumulateMenuViewSummary(from view: NSView, into summary: inout MenuStructureSummary) {
        summary.totalViews += 1
        let typeName = String(describing: type(of: view))
        if typeName.contains("HostingView") {
            summary.hostingViews += 1
        }
        if view is NSButton {
            summary.buttonViews += 1
        }
        if view.wantsLayer || view.layer != nil {
            summary.layerBackedViews += 1
        }
        for subview in view.subviews {
            self.accumulateMenuViewSummary(from: subview, into: &summary)
        }
    }

    private func isChartSubviewMenu(_ menu: NSMenu) -> Bool {
        let ids: Set<String> = [
            Self.usageBreakdownChartID,
            Self.creditsHistoryChartID,
            Self.costHistoryChartID,
            Self.usageHistoryChartID,
        ]
        return menu.items.contains { item in
            guard let id = item.representedObject as? String else { return false }
            return ids.contains(id)
        }
    }
}
