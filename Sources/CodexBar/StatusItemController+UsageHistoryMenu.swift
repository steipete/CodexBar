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
    func addUsageHistoryMenuItemIfNeeded(to menu: NSMenu, provider: UsageProvider) -> Bool {
        guard let submenu = self.makeUsageHistorySubmenu(provider: provider) else { return false }
        let width: CGFloat = 310
        let item = self.makeMenuCardItem(
            HStack(spacing: 0) {
                Text("Subscription Utilization")
                    .font(.system(size: NSFont.menuFont(ofSize: 0).pointSize))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14)
                    .padding(.trailing, 28)
                    .padding(.vertical, 8)
            },
            id: "usageHistorySubmenu",
            width: width,
            submenu: submenu,
            submenuIndicatorAlignment: .trailing,
            submenuIndicatorTopPadding: 0)
        menu.addItem(item)
        return true
    }

    private func makeUsageHistorySubmenu(provider: UsageProvider) -> NSMenu? {
        guard self.store.supportsPlanUtilizationHistory(for: provider) else { return nil }
        guard !self.store.shouldHidePlanUtilizationMenuItem(for: provider) else { return nil }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.usageHistoryChartID, provider: provider)
    }

    func appendUsageHistoryChartItem(
        to submenu: NSMenu,
        provider: UsageProvider,
        width: CGFloat) -> Bool
    {
        let histories = self.store.planUtilizationHistory(for: provider)
        let snapshot = self.store.snapshot(for: provider)

        if !Self.menuCardRenderingEnabled {
            let chartItem = NSMenuItem()
            chartItem.isEnabled = false
            chartItem.representedObject = Self.usageHistoryChartID
            submenu.addItem(chartItem)
            return true
        }

        let chartView = PlanUtilizationHistoryChartMenuView(
            provider: provider,
            histories: histories,
            snapshot: snapshot,
            width: width)
        let hosting = UsageHistoryMenuHostingView(rootView: chartView)
        let controller = NSHostingController(rootView: chartView)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = false
        chartItem.representedObject = Self.usageHistoryChartID
        submenu.addItem(chartItem)
        return true
    }
}
