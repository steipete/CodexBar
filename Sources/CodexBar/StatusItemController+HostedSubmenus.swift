import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    func makeHostedSubviewPlaceholderMenu(chartID: String, provider: UsageProvider? = nil) -> NSMenu {
        let submenu = NSMenu()
        submenu.delegate = self
        let chartItem = NSMenuItem()
        chartItem.isEnabled = false
        chartItem.representedObject = chartID
        chartItem.toolTip = provider?.rawValue
        submenu.addItem(chartItem)
        return submenu
    }

    func hydrateHostedSubviewMenuIfNeeded(_ menu: NSMenu) {
        guard let placeholder = menu.items.first,
              menu.items.count == 1,
              placeholder.view == nil,
              let chartID = placeholder.representedObject as? String
        else {
            return
        }

        let width = self.renderedMenuWidth(for: menu.supermenu ?? menu)
        menu.removeAllItems()

        let didHydrate: Bool = switch chartID {
        case Self.usageBreakdownChartID:
            self.appendUsageBreakdownChartItem(to: menu, width: width)
        case Self.creditsHistoryChartID:
            self.appendCreditsHistoryChartItem(to: menu, width: width)
        case Self.costHistoryChartID:
            if let providerRawValue = placeholder.toolTip,
               let provider = UsageProvider(rawValue: providerRawValue)
            {
                self.appendCostHistoryChartItem(to: menu, provider: provider, width: width)
            } else {
                false
            }
        case Self.usageHistoryChartID:
            if let providerRawValue = placeholder.toolTip,
               let provider = UsageProvider(rawValue: providerRawValue)
            {
                self.appendUsageHistoryChartItem(to: menu, provider: provider, width: width)
            } else {
                false
            }
        case Self.storageBreakdownID:
            if let providerRawValue = placeholder.toolTip,
               let provider = UsageProvider(rawValue: providerRawValue)
            {
                self.appendStorageBreakdownItem(to: menu, provider: provider, width: width)
            } else {
                false
            }
        default:
            false
        }

        guard !didHydrate else { return }

        let unavailableItem = NSMenuItem(title: "No data available", action: nil, keyEquivalent: "")
        unavailableItem.isEnabled = false
        unavailableItem.representedObject = chartID
        unavailableItem.toolTip = placeholder.toolTip
        menu.addItem(unavailableItem)
    }

    @discardableResult
    func appendUsageBreakdownChartItem(to submenu: NSMenu, width: CGFloat) -> Bool {
        let breakdown = OpenAIDashboardDailyBreakdown.removingSkillUsageServices(
            from: self.store.openAIDashboard?.usageBreakdown ?? [])
        guard !breakdown.isEmpty else { return false }

        if !Self.menuCardRenderingEnabled {
            let chartItem = NSMenuItem()
            chartItem.isEnabled = false
            chartItem.representedObject = Self.usageBreakdownChartID
            submenu.addItem(chartItem)
            return true
        }

        let chartView = UsageBreakdownChartMenuView(breakdown: breakdown, width: width)
        let hosting = MenuHostingView(rootView: chartView)
        let controller = NSHostingController(rootView: chartView)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = false
        chartItem.representedObject = Self.usageBreakdownChartID
        submenu.addItem(chartItem)
        return true
    }

    @discardableResult
    func appendCreditsHistoryChartItem(to submenu: NSMenu, width: CGFloat) -> Bool {
        let breakdown = self.store.openAIDashboard?.dailyBreakdown ?? []
        guard !breakdown.isEmpty else { return false }

        if !Self.menuCardRenderingEnabled {
            let chartItem = NSMenuItem()
            chartItem.isEnabled = false
            chartItem.representedObject = Self.creditsHistoryChartID
            submenu.addItem(chartItem)
            return true
        }

        let chartView = CreditsHistoryChartMenuView(breakdown: breakdown, width: width)
        let hosting = MenuHostingView(rootView: chartView)
        let controller = NSHostingController(rootView: chartView)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = false
        chartItem.representedObject = Self.creditsHistoryChartID
        submenu.addItem(chartItem)
        return true
    }

    @discardableResult
    func appendCostHistoryChartItem(
        to submenu: NSMenu,
        provider: UsageProvider,
        width: CGFloat) -> Bool
    {
        guard let tokenSnapshot = self.store.tokenSnapshot(for: provider) else { return false }
        guard !tokenSnapshot.daily.isEmpty else { return false }

        if !Self.menuCardRenderingEnabled {
            let chartItem = NSMenuItem()
            chartItem.isEnabled = false
            chartItem.representedObject = Self.costHistoryChartID
            submenu.addItem(chartItem)
            return true
        }

        let chartView = CostHistoryChartMenuView(
            provider: provider,
            daily: tokenSnapshot.daily,
            totalCostUSD: tokenSnapshot.last30DaysCostUSD,
            width: width)
        let hosting = MenuHostingView(rootView: chartView)
        let controller = NSHostingController(rootView: chartView)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = false
        chartItem.representedObject = Self.costHistoryChartID
        submenu.addItem(chartItem)
        return true
    }

    @discardableResult
    func appendStorageBreakdownItem(
        to submenu: NSMenu,
        provider: UsageProvider,
        width: CGFloat)
        -> Bool
    {
        guard let footprint = self.store.storageFootprint(for: provider),
              !footprint.components.isEmpty
        else { return false }

        if !Self.menuCardRenderingEnabled {
            let item = NSMenuItem()
            item.isEnabled = false
            item.representedObject = Self.storageBreakdownID
            item.toolTip = provider.rawValue
            submenu.addItem(item)
            return true
        }

        let maxHeight = self.storageBreakdownMenuMaxHeight()
        let view = StorageBreakdownMenuView(footprint: footprint, width: width, maxHeight: maxHeight)
        let hosting = MenuHostingView(rootView: view)
        let controller = NSHostingController(rootView: view)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: maxHeight))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))

        let item = NSMenuItem()
        item.view = hosting
        item.isEnabled = true
        item.representedObject = Self.storageBreakdownID
        item.toolTip = provider.rawValue
        submenu.addItem(item)
        return true
    }

    private func storageBreakdownMenuMaxHeight() -> CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        return min(620, max(360, floor(visibleHeight * 0.72)))
    }
}
