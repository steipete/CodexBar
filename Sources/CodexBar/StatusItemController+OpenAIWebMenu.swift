import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    struct OpenAIWebMenuItems {
        let hasUsageBreakdown: Bool
        let hasCreditsHistory: Bool
        let hasCostHistory: Bool
    }

    struct OpenAIWebContext {
        let hasUsageBreakdown: Bool
        let hasCreditsHistory: Bool
        let hasCostHistory: Bool
        let hasOpenAIWebMenuItems: Bool
    }

    func openAIWebContext(
        currentProvider: UsageProvider,
        showAllTokenAccounts: Bool) -> OpenAIWebContext
    {
        let dashboard = self.store.openAIDashboard
        let openAIWebEligible = currentProvider == .codex &&
            self.store.openAIDashboardRequiresLogin == false &&
            dashboard != nil
        let hasCreditsHistory = openAIWebEligible && !(dashboard?.dailyBreakdown ?? []).isEmpty
        let hasUsageBreakdown = openAIWebEligible && !(dashboard?.usageBreakdown ?? []).isEmpty
        let hasCostHistory = self.settings.isCostUsageEffectivelyEnabled(for: currentProvider) &&
            (self.store.tokenSnapshot(for: currentProvider)?.daily.isEmpty == false)
        let hasOpenAIWebMenuItems = !showAllTokenAccounts &&
            (hasCreditsHistory || hasUsageBreakdown || hasCostHistory)
        return OpenAIWebContext(
            hasUsageBreakdown: hasUsageBreakdown,
            hasCreditsHistory: hasCreditsHistory,
            hasCostHistory: hasCostHistory,
            hasOpenAIWebMenuItems: hasOpenAIWebMenuItems)
    }

    func addOpenAIWebItemsIfNeeded(
        to menu: NSMenu,
        currentProvider: UsageProvider,
        context: OpenAIWebContext,
        addedOpenAIWebItems: Bool)
    {
        guard context.hasOpenAIWebMenuItems else { return }
        if !addedOpenAIWebItems {
            if context.hasUsageBreakdown {
                _ = self.addUsageBreakdownSubmenu(to: menu)
            }
            if context.hasCreditsHistory {
                _ = self.addCreditsHistorySubmenu(to: menu)
            }
            if context.hasCostHistory {
                _ = self.addCostHistorySubmenu(to: menu, provider: currentProvider)
            }
        }
        menu.addItem(.separator())
    }

    @discardableResult
    private func addCreditsHistorySubmenu(to menu: NSMenu) -> Bool {
        guard let submenu = self.makeCreditsHistorySubmenu() else { return false }
        let item = NSMenuItem(title: "Credits history", action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    @discardableResult
    private func addUsageBreakdownSubmenu(to menu: NSMenu) -> Bool {
        guard let submenu = self.makeUsageBreakdownSubmenu() else { return false }
        let item = NSMenuItem(title: "Usage breakdown", action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    @discardableResult
    private func addCostHistorySubmenu(to menu: NSMenu, provider: UsageProvider) -> Bool {
        guard let submenu = self.makeCostHistorySubmenu(provider: provider) else { return false }
        let item = NSMenuItem(title: "Usage history (30 days)", action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    func makeUsageSubmenu(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        webItems: OpenAIWebMenuItems) -> NSMenu?
    {
        if provider == .codex, webItems.hasUsageBreakdown {
            return self.makeUsageBreakdownSubmenu()
        }
        if provider == .zai {
            return self.makeZaiUsageDetailsSubmenu(snapshot: snapshot)
        }
        return nil
    }

    private func makeUsageBreakdownSubmenu() -> NSMenu? {
        let breakdown = self.store.openAIDashboard?.usageBreakdown ?? []
        let width = Self.menuCardBaseWidth
        guard !breakdown.isEmpty else { return nil }

        if !Self.menuCardRenderingEnabled {
            let submenu = NSMenu()
            submenu.delegate = self
            let chartItem = NSMenuItem()
            chartItem.isEnabled = false
            chartItem.representedObject = "usageBreakdownChart"
            submenu.addItem(chartItem)
            return submenu
        }

        let submenu = NSMenu()
        submenu.delegate = self
        let chartView = UsageBreakdownChartMenuView(breakdown: breakdown, width: width)
        let hosting = MenuHostingView(rootView: chartView)
        let controller = NSHostingController(rootView: chartView)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = false
        chartItem.representedObject = "usageBreakdownChart"
        submenu.addItem(chartItem)
        return submenu
    }

    func makeCreditsHistorySubmenu() -> NSMenu? {
        let breakdown = self.store.openAIDashboard?.dailyBreakdown ?? []
        let width = Self.menuCardBaseWidth
        guard !breakdown.isEmpty else { return nil }

        if !Self.menuCardRenderingEnabled {
            let submenu = NSMenu()
            submenu.delegate = self
            let chartItem = NSMenuItem()
            chartItem.isEnabled = false
            chartItem.representedObject = "creditsHistoryChart"
            submenu.addItem(chartItem)
            return submenu
        }

        let submenu = NSMenu()
        submenu.delegate = self
        let chartView = CreditsHistoryChartMenuView(breakdown: breakdown, width: width)
        let hosting = MenuHostingView(rootView: chartView)
        let controller = NSHostingController(rootView: chartView)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = false
        chartItem.representedObject = "creditsHistoryChart"
        submenu.addItem(chartItem)
        return submenu
    }

    func makeCostHistorySubmenu(provider: UsageProvider) -> NSMenu? {
        guard provider == .codex || provider == .claude || provider == .vertexai else { return nil }
        let width = Self.menuCardBaseWidth
        guard let tokenSnapshot = self.store.tokenSnapshot(for: provider) else { return nil }
        guard !tokenSnapshot.daily.isEmpty else { return nil }

        if !Self.menuCardRenderingEnabled {
            let submenu = NSMenu()
            submenu.delegate = self
            let chartItem = NSMenuItem()
            chartItem.isEnabled = false
            chartItem.representedObject = "costHistoryChart"
            submenu.addItem(chartItem)
            return submenu
        }

        let submenu = NSMenu()
        submenu.delegate = self
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
        chartItem.representedObject = "costHistoryChart"
        submenu.addItem(chartItem)
        return submenu
    }
}
