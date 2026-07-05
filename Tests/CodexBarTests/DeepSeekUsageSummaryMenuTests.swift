import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct DeepSeekUsageSummaryMenuTests {
    private static func sampleUsage() -> DeepSeekUsageSummary {
        DeepSeekUsageSummary(
            todayTokens: 100,
            currentMonthTokens: 500,
            todayCost: 1.5,
            currentMonthCost: 7.5,
            requestCount: 3,
            currentMonthRequestCount: 12,
            topModel: "deepseek-chat",
            categoryBreakdown: [
                DeepSeekCategoryBreakdown(category: .promptCacheHitToken, tokens: 60, cost: 0.5),
                DeepSeekCategoryBreakdown(category: .promptCacheMissToken, tokens: 20, cost: 0.5),
            ],
            daily: [
                DeepSeekDailyUsage(date: "2026-05-26", totalTokens: 500, cost: 7.5, requestCount: 12),
            ],
            currency: "USD",
            updatedAt: Date())
    }

    private static func makeController(
        settings: SettingsStore,
        store: UsageStore) -> StatusItemController
    {
        StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: NSStatusBar.system)
    }

    @Test
    func `creates token usage details submenu when usage data exists`() throws {
        let suite = "DeepSeekUsageSummaryMenuTests-submenu"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.showOptionalCreditsAndExtraUsage = true

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "USD",
            totalBalance: 10,
            grantedBalance: 0,
            toppedUpBalance: 10,
            usageSummary: Self.sampleUsage(),
            updatedAt: Date()).toUsageSnapshot()
        store._setSnapshotForTesting(snapshot, provider: .deepseek)

        let controller = Self.makeController(settings: settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }

        let submenu = controller.makeDeepSeekUsageSummarySubmenu(provider: .deepseek, width: 310)
        #expect(submenu != nil)
        #expect(submenu?.items.first?.representedObject as? String == StatusItemController.deepSeekUsageSummaryChartID)

        let menu = NSMenu()
        #expect(controller.addDeepSeekUsageSummaryMenuItemIfNeeded(to: menu, provider: .deepseek, width: 310))
        #expect(menu.items.contains { $0.title == L("Token usage details") })
    }

    @Test
    func `hides token usage details submenu when optional usage is disabled`() throws {
        let suite = "DeepSeekUsageSummaryMenuTests-hidden"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.showOptionalCreditsAndExtraUsage = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "USD",
            totalBalance: 10,
            grantedBalance: 0,
            toppedUpBalance: 10,
            usageSummary: Self.sampleUsage(),
            updatedAt: Date()).toUsageSnapshot()
        store._setSnapshotForTesting(snapshot, provider: .deepseek)

        let controller = Self.makeController(settings: settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.makeDeepSeekUsageSummarySubmenu(provider: .deepseek, width: 310) == nil)
    }
}
