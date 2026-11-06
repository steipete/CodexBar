import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct MenuCardVisibilityTests {
    @Test
    func `closed menus stop resolving live cards and reopen with current values`() throws {
        _ = NSApplication.shared
        let settings = testSettingsStore(
            suiteName: #function,
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        enableTestProviders([.openai], settings: settings)
        settings.mergeIcons = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(userDefaults: InMemoryUserDefaults()),
            menuCardRenderingEnabled: false,
            menuRefreshEnabled: false)
        defer {
            controller.releaseStatusItemsForTesting()
            store.stopSharedSpendDashboardPublication()
            settings.configFileWatcher?.stop()
        }
        let menu = controller.makeMenu()
        let model = try #require(controller.menuCardModel(for: .openai))
        var resolutions = 0
        var latest = model
        let monitor = MenuCardRefreshMonitor(
            resolveModel: { _ in resolutions += 1; return latest },
            isProviderRefreshActive: { _ in false })
        controller.menuCardRefreshMonitor = monitor
        controller.openMenus[ObjectIdentifier(menu)] = menu
        controller.beginMenuTrackingSession(for: menu)
        let fallback = MenuCardLiveSubtitle(text: "Initial", style: .info)
        _ = monitor.model(for: .openai, fallback: model)
        #expect(resolutions == 1)
        let child = NSMenu()
        controller.openMenus[ObjectIdentifier(child)] = child
        controller.menuDidClose(menu)
        resolutions = 0
        _ = monitor.model(for: .openai, fallback: model)
        #expect(resolutions == 1)
        controller.menuDidClose(child)
        resolutions = 0
        for _ in 0..<20 {
            _ = monitor.model(for: .openai, fallback: model)
            _ = monitor.subtitle(for: .openai, fallback: fallback)
        }
        #expect(resolutions == 0)
        resolutions = 0
        store._setSnapshotForTesting(UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date()), provider: .openai)
        latest = try #require(controller.menuCardModel(for: .openai))
        controller.openMenus[ObjectIdentifier(menu)] = menu
        controller.beginMenuTrackingSession(for: menu)
        #expect(monitor.subtitle(for: .openai, fallback: fallback).text == latest.subtitleText)
        #expect(resolutions == 1)
        controller.menuDidClose(menu)
    }
}
