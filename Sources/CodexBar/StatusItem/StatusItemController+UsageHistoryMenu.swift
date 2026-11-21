import AppKit
import CodexBarCore
import SwiftUI

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
        return self.makeHostedSubviewPlaceholderMenu(
            chartID: Self.usageHistoryChartID, provider: provider, width: width)
    }

    func appendUsageHistoryChartItem(
        to submenu: NSMenu,
        provider: UsageProvider,
        width: CGFloat) -> Bool
    {
        let (selection, snapshot) = self.usageHistorySource(for: provider)

        if !self.menuCardRenderingEnabledForController {
            let chartItem = NSMenuItem()
            chartItem.isEnabled = true
            chartItem.representedObject = Self.usageHistoryChartID
            chartItem.toolTip = provider.rawValue
            submenu.addItem(chartItem)
            return true
        }

        // Provider-specific by design: this menu burndown currently targets Codex, Claude, and Kiro quota histories.
        if provider == .codex || provider == .claude || provider == .kiro {
            let burndownView = QuotaBurndownChartMenuView(
                provider: provider,
                histories: selection.histories,
                width: width)
            if burndownView.hasSeries {
                self.appendHistoryChart(burndownView, to: submenu, provider: provider, width: width)
                submenu.addItem(.separator())
            }
        }

        let chartView = PlanUtilizationHistoryChartMenuView(
            provider: provider,
            histories: selection.histories,
            snapshot: snapshot,
            width: width)
        self.appendHistoryChart(chartView, to: submenu, provider: provider, width: width)
        return true
    }

    /// History and snapshot behind the Plan Usage submenu. When claude-swap rows own the Claude menu,
    /// the chart follows the presented account (the same one the Overview Claude card shows); ambient
    /// Claude history can point at an account that stopped refreshing once claude-swap took over.
    /// A Fleet fallback card renders ahead of the swap rows, so it keeps the ambient source.
    func usageHistorySource(
        for provider: UsageProvider) -> (selection: PlanUtilizationHistorySelection, snapshot: UsageSnapshot?)
    {
        if let account = self.store.claudeSwapMenuDisplay(
            for: provider,
            inspectedAccountID: self.claudeSwapInspectedAccountID)?.displayedAccount,
            self.fleetAccountProjection(for: provider).fallback == nil
        {
            return (self.store.claudeSwapPlanUtilizationHistorySelection(for: account), account.snapshot)
        }
        return (
            self.store.planUtilizationHistorySelection(for: provider),
            self.store.snapshot(for: provider.instanceID))
    }

    func appendHistoryChart(
        _ chartView: some View,
        to submenu: NSMenu,
        id: String = StatusItemController.usageHistoryChartID,
        provider: UsageProvider? = nil,
        width: CGFloat)
    {
        let hosting = MenuHostingView(rootView: chartView)
        hosting.frame = NSRect(
            origin: .zero,
            size: NSSize(width: width, height: self.hostedSubviewFittingHeight(for: hosting, width: width)))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = true
        chartItem.representedObject = id
        chartItem.toolTip = provider?.rawValue
        submenu.addItem(chartItem)
    }
}
