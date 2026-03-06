import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    @discardableResult
    func addUsageHistoryMenuItemIfNeeded(to menu: NSMenu, provider: UsageProvider) -> Bool {
        guard let submenu = self.makeUsageHistorySubmenu(provider: provider) else { return false }
        let item = NSMenuItem(title: "Subscription Utilization", action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    private func makeUsageHistorySubmenu(provider: UsageProvider) -> NSMenu? {
        guard provider == .codex || provider == .claude else { return nil }
        let width: CGFloat = 310
        let submenu = NSMenu()
        submenu.delegate = self
        return self.appendUsageHistoryChartItem(to: submenu, provider: provider, width: width) ? submenu : nil
    }

    private func appendUsageHistoryChartItem(
        to submenu: NSMenu,
        provider: UsageProvider,
        width: CGFloat) -> Bool
    {
        let samples = self.store.planUtilizationHistory(for: provider)

        if !Self.menuCardRenderingEnabled {
            let chartItem = NSMenuItem()
            chartItem.isEnabled = false
            chartItem.representedObject = "usageHistoryChart"
            submenu.addItem(chartItem)
            return true
        }

        let chartView = PlanUtilizationHistoryChartMenuView(provider: provider, samples: samples, width: width)
        let hosting = MenuHostingView(rootView: chartView)
        let controller = NSHostingController(rootView: chartView)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = false
        chartItem.representedObject = "usageHistoryChart"
        submenu.addItem(chartItem)
        return true
    }
}
