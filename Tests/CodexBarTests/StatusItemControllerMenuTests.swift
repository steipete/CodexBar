import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct StatusItemControllerMenuTests {
    private func makeSnapshot(
        primary: RateWindow?,
        secondary: RateWindow?,
        tertiary: RateWindow? = nil,
        providerCost: ProviderCostSnapshot? = nil)
        -> UsageSnapshot
    {
        UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            providerCost: providerCost,
            updatedAt: Date())
    }

    @Test
    func `cursor switcher falls back to on demand budget when plan exhausted and showing remaining`() {
        let primary = RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let secondary = RateWindow(usedPercent: 36, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let providerCost = ProviderCostSnapshot(
            used: 12,
            limit: 200,
            currencyCode: "USD",
            updatedAt: Date())
        let snapshot = self.makeSnapshot(primary: primary, secondary: secondary, providerCost: providerCost)

        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .cursor,
            snapshot: snapshot,
            showUsed: false)

        #expect(percent == 94)
    }

    @Test
    func `cursor switcher uses primary when showing used`() {
        let primary = RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let secondary = RateWindow(usedPercent: 36, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let snapshot = self.makeSnapshot(primary: primary, secondary: secondary)

        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .cursor,
            snapshot: snapshot,
            showUsed: true)

        #expect(percent == 100)
    }

    @Test
    func `cursor switcher keeps primary when remaining is positive`() {
        let primary = RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let secondary = RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let snapshot = self.makeSnapshot(primary: primary, secondary: secondary)

        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .cursor,
            snapshot: snapshot,
            showUsed: false)

        #expect(percent == 80)
    }

    @Test
    func `cursor switcher does not treat auto lane as extra remaining quota`() {
        let primary = RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let secondary = RateWindow(usedPercent: 36, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let snapshot = self.makeSnapshot(primary: primary, secondary: secondary)

        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .cursor,
            snapshot: snapshot,
            showUsed: false)

        #expect(percent == 0)
    }

    @Test
    func `perplexity switcher falls back after recurring credits are exhausted`() {
        let primary = RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let secondary = RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let tertiary = RateWindow(usedPercent: 24, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let snapshot = self.makeSnapshot(primary: primary, secondary: secondary, tertiary: tertiary)

        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .perplexity,
            snapshot: snapshot,
            showUsed: false)

        #expect(percent == 76)
    }

    @Test
    func `open router brand fallback enabled when no key limit configured`() {
        let snapshot = OpenRouterUsageSnapshot(
            totalCredits: 50,
            totalUsage: 45,
            balance: 5,
            usedPercent: 90,
            keyDataFetched: true,
            keyLimit: nil,
            keyUsage: nil,
            rateLimit: nil,
            updatedAt: Date()).toUsageSnapshot()

        #expect(StatusItemController.shouldUseOpenRouterBrandFallback(
            provider: .openrouter,
            snapshot: snapshot))
        #expect(MenuBarDisplayText.percentText(window: snapshot.primary, showUsed: false) == nil)
    }

    @Test
    func `open router brand fallback disabled when key quota fetch unavailable`() {
        let snapshot = OpenRouterUsageSnapshot(
            totalCredits: 50,
            totalUsage: 45,
            balance: 5,
            usedPercent: 90,
            keyDataFetched: false,
            keyLimit: nil,
            keyUsage: nil,
            rateLimit: nil,
            updatedAt: Date()).toUsageSnapshot()

        #expect(!StatusItemController.shouldUseOpenRouterBrandFallback(
            provider: .openrouter,
            snapshot: snapshot))
    }

    @Test
    func `open router brand fallback disabled when key quota available`() {
        let snapshot = OpenRouterUsageSnapshot(
            totalCredits: 50,
            totalUsage: 45,
            balance: 5,
            usedPercent: 90,
            keyLimit: 20,
            keyUsage: 2,
            rateLimit: nil,
            updatedAt: Date()).toUsageSnapshot()

        #expect(!StatusItemController.shouldUseOpenRouterBrandFallback(
            provider: .openrouter,
            snapshot: snapshot))
        #expect(snapshot.primary?.usedPercent == 10)
    }
}
