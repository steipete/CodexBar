import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct StatusMenuSessionAnalyticsTests {
    private func disableMenuCardsForTesting() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.menuRefreshEnabled = false
    }

    private func makeStatusBarForTesting() -> NSStatusBar {
        let env = ProcessInfo.processInfo.environment
        if env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" {
            return .system
        }
        return NSStatusBar()
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuSessionAnalyticsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    @Test
    func `codex menu includes session analytics submenu when snapshot is present`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let snapshot = CodexSessionAnalyticsSnapshot(
            generatedAt: Date(),
            sessions: [
                CodexSessionSummary(
                    id: "session-1",
                    title: "Test session",
                    startedAt: Date(),
                    durationSeconds: 45,
                    toolCallCount: 3,
                    toolFailureCount: 1,
                    longRunningCallCount: 1,
                    verificationAttemptCount: 1,
                    toolCountsByName: ["exec_command": 2, "write_stdin": 1]),
            ],
            medianSessionDurationSeconds: 45,
            medianToolCallsPerSession: 3,
            toolFailureRate: 1.0 / 3.0,
            topTools: [
                CodexToolAggregate(name: "exec_command", callCount: 2),
                CodexToolAggregate(name: "write_stdin", callCount: 1),
            ])
        store.codexSessionAnalytics = snapshot
        store.codexSessionAnalyticsCacheByWindow[settings.codexSessionAnalyticsWindowSize] = snapshot
        store.lastCodexSessionAnalyticsRefreshAt = Date()
        store.codexSessionAnalyticsLastSuccessfulRefreshAt = Date()

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        let analyticsItem = menu.items.first { ($0.representedObject as? String) == "sessionAnalyticsSubmenu" }
        #expect(analyticsItem != nil)
        #expect(analyticsItem?.submenu?.items.isEmpty == true)
        if let submenu = analyticsItem?.submenu {
            controller.menuWillOpen(submenu)
        }
        #expect(analyticsItem?.submenu?.items.contains {
            ($0.representedObject as? String) == "sessionAnalyticsContent"
        } == true)
    }

    @Test
    func `codex session analytics submenu exposes empty state without local data`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.codexSessionAnalytics = nil
        store.codexSessionAnalyticsError = nil
        store.lastCodexSessionAnalyticsRefreshAt = Date()

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        let analyticsItem = menu.items.first { ($0.representedObject as? String) == "sessionAnalyticsSubmenu" }
        #expect(analyticsItem != nil)
        #expect(analyticsItem?.submenu?.items.isEmpty == true)
        if let submenu = analyticsItem?.submenu {
            controller.menuWillOpen(submenu)
        }
        #expect(analyticsItem?.submenu?.items.contains {
            ($0.representedObject as? String) == "sessionAnalyticsEmptyState"
        } == true)
    }

    @Test
    func `codex session analytics submenu repopulates when reopened`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.codexSessionAnalytics = nil
        store.codexSessionAnalyticsError = nil
        store.lastCodexSessionAnalyticsRefreshAt = Date()

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        let analyticsItem = try #require(menu.items.first {
            ($0.representedObject as? String) == "sessionAnalyticsSubmenu"
        })
        let submenu = try #require(analyticsItem.submenu)

        controller.menuWillOpen(submenu)
        #expect(submenu.items.contains {
            ($0.representedObject as? String) == "sessionAnalyticsEmptyState"
        })

        let snapshot = CodexSessionAnalyticsSnapshot(
            generatedAt: Date(),
            sessions: [
                CodexSessionSummary(
                    id: "session-2",
                    title: "Updated session",
                    startedAt: Date(),
                    durationSeconds: 30,
                    toolCallCount: 2,
                    toolFailureCount: 0,
                    longRunningCallCount: 0,
                    verificationAttemptCount: 1,
                    toolCountsByName: ["exec_command": 2]),
            ],
            medianSessionDurationSeconds: 30,
            medianToolCallsPerSession: 2,
            toolFailureRate: 0,
            topTools: [
                CodexToolAggregate(name: "exec_command", callCount: 2),
            ])
        store.codexSessionAnalytics = snapshot
        store.codexSessionAnalyticsCacheByWindow[settings.codexSessionAnalyticsWindowSize] = snapshot
        store.lastCodexSessionAnalyticsRefreshAtByWindow.removeAll()
        store.codexSessionAnalyticsErrorCacheByWindow.removeAll()
        store.lastCodexSessionAnalyticsRefreshAt = Date()
        store.codexSessionAnalyticsLastSuccessfulRefreshAt = Date()

        controller.menuWillOpen(submenu)
        #expect(submenu.items.contains {
            ($0.representedObject as? String) == "sessionAnalyticsContent"
        })
    }
}
