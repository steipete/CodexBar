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
        let startedAt = Date()
        let histories = self.store.planUtilizationHistoryForMenu(for: provider)
        let historyMs = Date().timeIntervalSince(startedAt) * 1000
        let snapshot = self.store.snapshot(for: provider)

        if !Self.menuCardRenderingEnabled {
            let chartItem = NSMenuItem()
            chartItem.isEnabled = true
            chartItem.representedObject = Self.usageHistoryChartID
            submenu.addItem(chartItem)
            return true
        }

        let chartView = PlanUtilizationHistoryChartMenuView(
            provider: provider,
            histories: histories,
            snapshot: snapshot,
            width: width)
        let hostingStartedAt = Date()
        let hosting = UsageHistoryMenuHostingView(rootView: chartView)
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1))
        let hostingMs = Date().timeIntervalSince(hostingStartedAt) * 1000
        let sizeStartedAt = Date()
        let size = hosting.fittingSize
        let sizeMs = Date().timeIntervalSince(sizeStartedAt) * 1000
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = true
        chartItem.representedObject = Self.usageHistoryChartID
        submenu.addItem(chartItem)
        let totalMs = Date().timeIntervalSince(startedAt) * 1000
        if totalMs >= 16 {
            self.menuLogger.info(
                "usage history submenu chart built",
                metadata: [
                    "entries": "\(histories.reduce(0) { $0 + $1.entries.count })",
                    "historyMs": String(format: "%.1f", historyMs),
                    "hostingMs": String(format: "%.1f", hostingMs),
                    "provider": provider.rawValue,
                    "sizeMs": String(format: "%.1f", sizeMs),
                    "totalMs": String(format: "%.1f", totalMs),
                    "width": String(format: "%.0f", width),
                ])
        }
        return true
    }
}
