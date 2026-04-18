import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct CodexConsumerProjectionCharacterizationTests {
    private func makeStatusBarForTesting() -> NSStatusBar {
        let env = ProcessInfo.processInfo.environment
        if env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" {
            return .system
        }
        return NSStatusBar()
    }

    private func makeSettings() -> SettingsStore {
        let suite = "CodexConsumerProjectionCharacterizationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func makeCodexStore(settings: SettingsStore, dashboardAuthorized: Bool) -> UsageStore {
        let now = Date()
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 22,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(1800),
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "codex@example.com",
                    accountOrganization: nil,
                    loginMethod: "Plus Plan")),
            provider: .codex)
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "other@example.com",
            codeReviewRemainingPercent: 88,
            codeReviewLimit: RateWindow(
                usedPercent: 12,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: now)
        store.openAIDashboardAttachmentAuthorized = dashboardAuthorized
        store.openAIDashboardRequiresLogin = false
        return store
    }

    @Test
    func `snapshot override menu card stays isolated from live codex extras`() throws {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual

        let fetcher = UsageFetcher()
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: true)
        store.credits = CreditsSnapshot(remaining: 42, events: [], updatedAt: Date())
        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: 123,
            sessionCostUSD: 1.23,
            last30DaysTokens: 456,
            last30DaysCostUSD: 4.56,
            daily: [],
            updatedAt: Date()), provider: .codex)
        store._setErrorForTesting("Live store error", provider: .codex)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let overrideSnapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 15,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(1800),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "override@example.com",
                accountOrganization: nil,
                loginMethod: "Plus Plan"))

        let model = try #require(controller.menuCardModel(
            for: .codex,
            snapshotOverride: overrideSnapshot,
            errorOverride: "Override error"))

        #expect(model.creditsText == "Credits unavailable; keep Codex running to refresh.")
        #expect(model.tokenUsage == nil)
        #expect(model.metrics.contains { $0.id == "code-review" } == false)
        #expect(model.subtitleText == "Override error")
    }

    @Test
    func `menu bar display text keeps percent in show used mode when codex is exhausted`() {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarDisplayMode = .percent
        settings.usageBarsShowUsed = true
        settings.setMenuBarMetricPreference(.primary, for: .codex)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)
        store.credits = CreditsSnapshot(remaining: 80, events: [], updatedAt: Date())

        let displayText = controller.menuBarDisplayText(for: .codex, snapshot: snapshot)

        #expect(displayText == "100%")
    }
}
