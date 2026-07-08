import AppKit
import CodexBarCore

extension StatusItemController {
    @discardableResult
    func addMiniMaxUsageSummaryMenuItemIfNeeded(to menu: NSMenu, provider: UsageProvider, width: CGFloat) -> Bool {
        guard let submenu = self.makeMiniMaxUsageSummarySubmenu(provider: provider, width: width) else { return false }
        let item = NSMenuItem(title: L("Token usage details"), action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.representedObject = "miniMaxUsageSummarySubmenu"
        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    func makeMiniMaxUsageSummarySubmenu(provider: UsageProvider, width: CGFloat? = nil) -> NSMenu? {
        guard self.settings.showOptionalCreditsAndExtraUsage,
              provider == .minimax,
              let usage = self.store.snapshot(for: provider)?.minimaxUsage?.usageSummary,
              usage.hasDisplayableData
        else {
            return nil
        }
        if let width {
            return self.makeHostedSubviewPlaceholderMenu(
                chartID: Self.miniMaxUsageSummaryChartID,
                provider: provider,
                width: width)
        }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.miniMaxUsageSummaryChartID, provider: provider)
    }

    func minimaxShowsUsageSummaryOnMainCard(provider: UsageProvider) -> Bool {
        guard provider == .minimax, self.settings.showOptionalCreditsAndExtraUsage else { return false }
        guard let usage = self.store.snapshot(for: provider)?.minimaxUsage?.usageSummary,
              usage.hasDisplayableData
        else {
            return false
        }
        return true
    }

    @discardableResult
    func appendMiniMaxUsageSummaryChartItem(
        to submenu: NSMenu,
        provider: UsageProvider,
        width: CGFloat) -> Bool
    {
        guard self.settings.showOptionalCreditsAndExtraUsage,
              provider == .minimax,
              let usage = self.store.snapshot(for: provider)?.minimaxUsage?.usageSummary,
              usage.hasDisplayableData
        else {
            return false
        }

        if !self.menuCardRenderingEnabledForController {
            let chartItem = NSMenuItem()
            chartItem.isEnabled = true
            chartItem.representedObject = Self.miniMaxUsageSummaryChartID
            chartItem.toolTip = provider.rawValue
            submenu.addItem(chartItem)
            return true
        }

        final class HostingRelay {
            weak var hosting: MenuHostingView<MiniMaxUsageSummaryChartMenuView>?
            var minimumHeight: CGFloat = 1
        }
        let relay = HostingRelay()
        let showsSummaryKPIs = !self.minimaxShowsUsageSummaryOnMainCard(provider: provider)
        let chartView = MiniMaxUsageSummaryChartMenuView(
            usage: usage,
            showsSummaryKPIs: showsSummaryKPIs,
            onHeightChange: { height in
                let resolved = max(height, relay.minimumHeight)
                relay.hosting?.applyMeasuredHeight(width: width, height: resolved)
            },
            width: width)
        let hosting = MenuHostingView(rootView: chartView)
        relay.hosting = hosting
        let fittedHeight = self.hostedSubviewFittingHeight(for: hosting, width: width)
        relay.minimumHeight = fittedHeight
        hosting.applyMeasuredHeight(width: width, height: fittedHeight)

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = true
        chartItem.representedObject = Self.miniMaxUsageSummaryChartID
        chartItem.toolTip = provider.rawValue
        submenu.addItem(chartItem)
        return true
    }
}
