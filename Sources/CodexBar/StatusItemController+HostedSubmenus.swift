import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    func isHostedSubviewMenu(_ menu: NSMenu) -> Bool {
        let ids: Set = [
            Self.usageBreakdownChartID,
            Self.creditsHistoryChartID,
            Self.costHistoryChartID,
            Self.openAIAPIUsageChartID,
            Self.usageHistoryChartID,
            Self.storageBreakdownID,
            Self.zaiHourlyUsageChartID,
        ]
        return menu.items.contains { item in
            guard let id = item.representedObject as? String else { return false }
            return ids.contains(id)
        }
    }

    func makeHostedSubviewPlaceholderMenu(
        chartID: String,
        provider: UsageProvider? = nil,
        width: CGFloat? = nil) -> NSMenu
    {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        if let width {
            submenu.minimumWidth = width
        }
        submenu.delegate = self
        let chartItem = NSMenuItem()
        chartItem.isEnabled = true
        chartItem.representedObject = chartID
        chartItem.toolTip = provider?.rawValue
        submenu.addItem(chartItem)
        return submenu
    }

    func hydrateHostedSubviewMenuIfNeeded(_ menu: NSMenu, width requestedWidth: CGFloat? = nil) {
        guard let placeholder = menu.items.first,
              menu.items.count == 1,
              placeholder.view == nil,
              let chartID = placeholder.representedObject as? String
        else {
            return
        }

        let width = requestedWidth ?? self.renderedMenuWidth(for: menu.supermenu ?? menu)
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
        case Self.openAIAPIUsageChartID:
            if let providerRawValue = placeholder.toolTip,
               let provider = UsageProvider(rawValue: providerRawValue)
            {
                self.appendOpenAIAPIUsageChartItem(to: menu, provider: provider, width: width)
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
        case Self.zaiHourlyUsageChartID:
            if let providerRawValue = placeholder.toolTip,
               let provider = UsageProvider(rawValue: providerRawValue)
            {
                self.appendZaiHourlyUsageChartItem(to: menu, provider: provider, width: width)
            } else {
                false
            }
        default:
            false
        }

        guard !didHydrate else { return }

        let unavailableItem = NSMenuItem(title: L("No data available"), action: nil, keyEquivalent: "")
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
            chartItem.isEnabled = true
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
        chartItem.isEnabled = true
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
            chartItem.isEnabled = true
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
        chartItem.isEnabled = true
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
            chartItem.isEnabled = true
            chartItem.representedObject = Self.costHistoryChartID
            submenu.addItem(chartItem)
            return true
        }

        let chartView = CostHistoryChartMenuView(
            provider: provider,
            daily: tokenSnapshot.daily,
            totalCostUSD: tokenSnapshot.last30DaysCostUSD,
            historyDays: tokenSnapshot.historyDays,
            width: width)
        let hosting = MenuHostingView(rootView: chartView)
        let controller = NSHostingController(rootView: chartView)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = true
        chartItem.representedObject = Self.costHistoryChartID
        submenu.addItem(chartItem)
        return true
    }

    @discardableResult
    func appendOpenAIAPIUsageChartItem(
        to submenu: NSMenu,
        provider: UsageProvider,
        width: CGFloat)
        -> Bool
    {
        guard provider == .openai,
              let snapshot = self.store.snapshot(for: provider)?.openAIAPIUsage,
              !snapshot.daily.isEmpty
        else { return false }

        if !Self.menuCardRenderingEnabled {
            let chartItem = NSMenuItem()
            chartItem.isEnabled = true
            chartItem.representedObject = Self.openAIAPIUsageChartID
            submenu.addItem(chartItem)
            return true
        }

        let chartView = OpenAIAPIUsageChartMenuView(snapshot: snapshot, width: width)
        let hosting = MenuHostingView(rootView: chartView)
        let controller = NSHostingController(rootView: chartView)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = true
        chartItem.representedObject = Self.openAIAPIUsageChartID
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
            item.isEnabled = true
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

    @discardableResult
    func appendZaiHourlyUsageChartItem(
        to submenu: NSMenu,
        provider: UsageProvider,
        width: CGFloat) -> Bool
    {
        guard provider == .zai,
              let snapshot = self.store.snapshot(for: provider),
              let modelUsage = snapshot.zaiUsage?.modelUsage
        else { return false }

        if !Self.menuCardRenderingEnabled {
            let chartItem = NSMenuItem()
            chartItem.isEnabled = false
            chartItem.representedObject = Self.zaiHourlyUsageChartID
            chartItem.toolTip = provider.rawValue
            submenu.addItem(chartItem)
            return true
        }

        let chartView = ZaiHourlyUsageChartMenuView(modelUsage: modelUsage, width: width)
        let hosting = MenuHostingView(rootView: chartView)
        let controller = NSHostingController(rootView: chartView)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = false
        chartItem.representedObject = Self.zaiHourlyUsageChartID
        chartItem.toolTip = provider.rawValue
        submenu.addItem(chartItem)
        return true
    }
}
