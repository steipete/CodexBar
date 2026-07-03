import AppKit
import CodexBarCore
import SwiftUI

private final class UsageHistoryMenuHostingView<Content: View>: NSHostingView<Content> {
    override var allowsVibrancy: Bool {
        true
    }
}

extension StatusItemController {
    @discardableResult
    func addUsageHistoryMenuItemIfNeeded(to menu: NSMenu, provider: UsageProvider, width: CGFloat) -> Bool {
        guard let submenu = self.makeUsageHistorySubmenu(provider: provider, width: width) else { return false }
        let item = NSMenuItem(title: L("Plan Usage"), action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.representedObject = "usageHistorySubmenu"
        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    func makeUsageHistorySubmenu(provider: UsageProvider, width: CGFloat? = nil) -> NSMenu? {
        guard self.store.supportsPlanUtilizationHistory(for: provider) else { return nil }
        guard !self.store.shouldHidePlanUtilizationMenuItem(for: provider) else { return nil }
        if let width {
            return self.makeHostedSubviewPlaceholderMenu(
                chartID: Self.usageHistoryChartID,
                provider: provider,
                width: width)
        }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.usageHistoryChartID, provider: provider)
    }

    func appendUsageHistoryChartItem(
        to submenu: NSMenu,
        provider: UsageProvider,
        width: CGFloat) -> Bool
    {
        let histories = self.store.planUtilizationHistory(for: provider)
        let snapshot = self.store.snapshot(for: provider)

        if !self.menuCardRenderingEnabledForController {
            let chartItem = NSMenuItem()
            chartItem.isEnabled = true
            chartItem.representedObject = Self.usageHistoryChartID
            chartItem.toolTip = provider.rawValue
            submenu.addItem(chartItem)
            return true
        }

        let chartView = PlanUtilizationHistoryChartMenuView(
            provider: provider,
            histories: histories,
            snapshot: snapshot,
            width: width)
        let hosting = UsageHistoryMenuHostingView(rootView: chartView)
        hosting.frame = NSRect(
            origin: .zero,
            size: NSSize(width: width, height: self.hostedSubviewFittingHeight(for: hosting, width: width)))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = true
        chartItem.representedObject = Self.usageHistoryChartID
        chartItem.toolTip = provider.rawValue
        submenu.addItem(chartItem)
        return true
    }
}
