import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct CodexConsumerProjectionCharacterizationTests {
    private func makeSettings() -> SettingsStore {
        testSettingsStore(suiteName: "CodexConsumerProjectionCharacterizationTests")
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

    private func enableCodexProvider(settings: SettingsStore) {
        if let codexMeta = ProviderRegistry.shared.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
    }

    private func makeMenuBarController(settings: SettingsStore) -> (UsageStore, StatusItemController) {
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return (store, controller)
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
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

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

        #expect(model.creditsText == nil)
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

        self.enableCodexProvider(settings: settings)

        let (store, controller) = self.makeMenuBarController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

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

    @Test
    func `menu bar percent mode can show codex session and weekly together`() {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarDisplayMode = .percent
        settings.usageBarsShowUsed = false
        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .codex)

        self.enableCodexProvider(settings: settings)

        let (store, controller) = self.makeMenuBarController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 7, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 18, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)
        store.credits = CreditsSnapshot(remaining: 42.5, events: [], updatedAt: Date())

        let displayText = controller.menuBarDisplayText(for: .codex, snapshot: snapshot)

        #expect(displayText == "5h 93% · W 82%")
    }

    @Test
    func `menu bar combined codex percent keeps available weekly lane when session is unavailable`() {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarDisplayMode = .percent
        settings.usageBarsShowUsed = false
        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .codex)

        self.enableCodexProvider(settings: settings)

        let (store, controller) = self.makeMenuBarController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 18, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)
        store.credits = CreditsSnapshot(remaining: 42.5, events: [], updatedAt: Date())

        let displayText = controller.menuBarDisplayText(for: .codex, snapshot: snapshot)

        #expect(displayText == "W 82%")
    }

    @Test
    func `menu bar combined codex percent falls back to credits when no percent lanes are available`() {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarDisplayMode = .percent
        settings.usageBarsShowUsed = false
        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .codex)

        self.enableCodexProvider(settings: settings)

        let (store, controller) = self.makeMenuBarController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let snapshot = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)
        store.credits = CreditsSnapshot(remaining: 42.5, events: [], updatedAt: Date())

        let displayText = controller.menuBarDisplayText(for: .codex, snapshot: snapshot)

        #expect(displayText == "42.5")
    }

    @Test
    func `menu bar combined codex percent keeps credits fallback when a lane is exhausted`() {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarDisplayMode = .percent
        settings.usageBarsShowUsed = false
        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .codex)

        self.enableCodexProvider(settings: settings)

        let (store, controller) = self.makeMenuBarController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 18, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)
        store.credits = CreditsSnapshot(remaining: 42.5, events: [], updatedAt: Date())

        let displayText = controller.menuBarDisplayText(for: .codex, snapshot: snapshot)

        #expect(displayText == "42.5")
    }

    @Test
    func `menu bar combined codex option preserves single metric choices`() {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarDisplayMode = .percent
        settings.usageBarsShowUsed = false

        self.enableCodexProvider(settings: settings)

        let (store, controller) = self.makeMenuBarController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 7, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 18, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)

        settings.setMenuBarMetricPreference(.primary, for: .codex)
        let primaryText = controller.menuBarDisplayText(for: .codex, snapshot: snapshot)

        settings.setMenuBarMetricPreference(.secondary, for: .codex)
        let secondaryText = controller.menuBarDisplayText(for: .codex, snapshot: snapshot)

        #expect(primaryText == "93%")
        #expect(secondaryText == "82%")
    }
}
