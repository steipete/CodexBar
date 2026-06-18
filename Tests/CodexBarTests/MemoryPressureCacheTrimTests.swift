import AppKit
import CodexBarCore
import Dispatch
import Testing
@testable import CodexBar

@MainActor
struct MemoryPressureCacheTrimTests {
    @Test
    func `memory pressure monitor invokes app cache trim and allocator relief handlers`() async {
        var handlerCalls = 0
        let releaseProbe = MemoryPressureReleaseProbe()
        let monitor = MemoryPressureMonitor(
            trimAppCaches: {
                handlerCalls += 1
                return MemoryPressureCacheTrimSummary(menuCardHeights: 1)
            },
            releaseFreeMallocPages: {
                releaseProbe.signal()
            })

        monitor.handleMemoryPressureForTesting(isWarning: true, isCritical: false)

        #expect(handlerCalls == 1)
        let releaseCompleted = await Task.detached {
            releaseProbe.wait(timeout: .now() + 2)
        }.value
        #expect(releaseCompleted)
    }

    @Test
    func `status controller trims rebuildable menu caches on memory pressure`() {
        let controller = self.makeController()
        defer { controller.releaseStatusItemsForTesting() }

        let key = StatusItemController.MenuCardHeightCacheKey(
            id: "card",
            scope: UsageProvider.codex.rawValue,
            width: 30000,
            textScale: StatusItemController.menuCardHeightTextScaleToken(),
            fingerprint: "content:stable")
        let menu = NSMenu()
        let entry = CachedMergedSwitcherMenuContent(
            requiredMenuContentVersion: 0,
            menuWidth: 300,
            codexAccountDisplay: nil,
            tokenAccountDisplay: nil,
            localizationSignature: "",
            items: [])

        controller.menuCardHeightCache[key] = 42
        controller.measuredStandardMenuWidthCache["width"] = 300
        controller.mergedSwitcherContentCaches[ObjectIdentifier(menu)] = [
            .overview: entry,
            .provider(.codex): entry,
        ]
        controller.menuCardViewRecyclePool["card"] = NSView()

        let summary = controller.trimRebuildableCachesForMemoryPressure()

        #expect(summary.menuCardHeights == 1)
        #expect(summary.menuWidths == 1)
        #expect(summary.mergedSwitcherSelections == 2)
        #expect(summary.recycledMenuCardViews == 1)
        #expect(controller.menuCardHeightCache.isEmpty)
        #expect(controller.measuredStandardMenuWidthCache.isEmpty)
        #expect(controller.mergedSwitcherContentCaches.isEmpty)
        #expect(controller.menuCardViewRecyclePool.isEmpty)
    }

    @Test
    func `usage store trims OpenAI web debug cache without interrupting active refresh state`() {
        let store = self.makeStore()
        let taskToken = UUID()

        store.openAIWebDebugLines = ["line 1", "line 2", "line 3"]
        store.openAIDashboardCookieImportDebugLog = "line 1\nline 2\nline 3"
        store.isRefreshing = true
        store.refreshingProviders = [.codex]
        store.tokenRefreshInFlight = [.codex]
        store.openAIDashboardRefreshTaskKey = "codex@example.com:manual"
        store.openAIDashboardRefreshTaskToken = taskToken

        let summary = store.trimRebuildableCachesForMemoryPressure()

        #expect(summary.openAIWebDebugLines == 3)
        #expect(store.openAIWebDebugLines.isEmpty)
        #expect(store.openAIDashboardCookieImportDebugLog == nil)
        #expect(store.isRefreshing)
        #expect(store.refreshingProviders == [.codex])
        #expect(store.tokenRefreshInFlight == [.codex])
        #expect(store.openAIDashboardRefreshTaskKey == "codex@example.com:manual")
        #expect(store.openAIDashboardRefreshTaskToken == taskToken)
    }

    private func makeController() -> StatusItemController {
        let settings = self.makeSettings()
        let store = self.makeStore(settings: settings)
        return StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
    }

    private func makeStore(settings: SettingsStore? = nil) -> UsageStore {
        let resolvedSettings = settings ?? self.makeSettings()
        return UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: resolvedSettings)
    }

    private func makeSettings() -> SettingsStore {
        let suite = "MemoryPressureCacheTrimTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.providerDetectionCompleted = true
        return settings
    }
}

private final class MemoryPressureReleaseProbe: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        self.semaphore.signal()
    }

    func wait(timeout: DispatchTime) -> Bool {
        self.semaphore.wait(timeout: timeout) == .success
    }
}
