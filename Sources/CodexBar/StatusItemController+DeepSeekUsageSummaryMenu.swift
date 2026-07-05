import AppKit
import CodexBarCore

extension StatusItemController {
    @discardableResult
    func addDeepSeekUsageSummaryMenuItemIfNeeded(to menu: NSMenu, provider: UsageProvider, width: CGFloat) -> Bool {
        guard let submenu = self.makeDeepSeekUsageSummarySubmenu(provider: provider, width: width) else { return false }
        let item = NSMenuItem(title: L("Token usage details"), action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.representedObject = "deepSeekUsageSummarySubmenu"
        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    func makeDeepSeekUsageSummarySubmenu(provider: UsageProvider, width: CGFloat? = nil) -> NSMenu? {
        guard self.settings.showOptionalCreditsAndExtraUsage,
              provider == .deepseek,
              let usage = self.store.snapshot(for: provider)?.deepseekUsage,
              usage.hasDisplayableData,
              !usage.daily.isEmpty
        else {
            return nil
        }
        if let width {
            return self.makeHostedSubviewPlaceholderMenu(
                chartID: Self.deepSeekUsageSummaryChartID,
                provider: provider,
                width: width)
        }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.deepSeekUsageSummaryChartID, provider: provider)
    }

    func deepSeekShowsUsageSummaryOnMainCard(provider: UsageProvider) -> Bool {
        guard provider == .deepseek, self.settings.showOptionalCreditsAndExtraUsage else { return false }
        guard let usage = self.store.snapshot(for: provider)?.deepseekUsage,
              usage.hasDisplayableData,
              !usage.daily.isEmpty
        else {
            return false
        }
        return true
    }

    @discardableResult
    func appendDeepSeekUsageSummaryChartItem(
        to submenu: NSMenu,
        provider: UsageProvider,
        width: CGFloat) -> Bool
    {
        guard self.settings.showOptionalCreditsAndExtraUsage,
              provider == .deepseek,
              let usage = self.store.snapshot(for: provider)?.deepseekUsage,
              usage.hasDisplayableData,
              !usage.daily.isEmpty
        else {
            return false
        }

        if !self.menuCardRenderingEnabledForController {
            let chartItem = NSMenuItem()
            chartItem.isEnabled = true
            chartItem.representedObject = Self.deepSeekUsageSummaryChartID
            chartItem.toolTip = provider.rawValue
            submenu.addItem(chartItem)
            return true
        }

        final class HostingRelay {
            weak var hosting: MenuHostingView<DeepSeekUsageSummaryChartMenuView>?
        }
        let relay = HostingRelay()
        let showsSummaryKPIs = !self.deepSeekShowsUsageSummaryOnMainCard(provider: provider)
        let chartView = DeepSeekUsageSummaryChartMenuView(
            usage: usage,
            showsSummaryKPIs: showsSummaryKPIs,
            onHeightChange: { height in
                relay.hosting?.applyMeasuredHeight(width: width, height: height)
            },
            width: width)
        let hosting = MenuHostingView(rootView: chartView)
        relay.hosting = hosting
        hosting.applyMeasuredHeight(
            width: width,
            height: max(
                hosting.measuredFittingHeight(width: width),
                self.hostedSubviewFittingHeight(for: hosting, width: width)))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = true
        chartItem.representedObject = Self.deepSeekUsageSummaryChartID
        chartItem.toolTip = provider.rawValue
        submenu.addItem(chartItem)
        return true
    }
}
