import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct StatusItemExtraUsageMetricTests {
    private func makeStatusBarForTesting() -> NSStatusBar {
        let env = ProcessInfo.processInfo.environment
        if env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" {
            return .system
        }
        return NSStatusBar()
    }

    @Test
    func `menu bar extra usage preference uses cursor on demand budget`() {
        let (store, controller) = self.makeCursorController(suiteName: "StatusItemExtraUsageMetricTests-budget")
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 72, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            providerCost: ProviderCostSnapshot(
                used: 15,
                limit: 100,
                currencyCode: "USD",
                updatedAt: Date()),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .cursor)
        store._setErrorForTesting(nil, provider: .cursor)

        let window = controller.menuBarMetricWindow(for: .cursor, snapshot: snapshot)

        #expect(window?.usedPercent == 15)
    }

    @Test
    func `menu bar extra usage preference falls back to automatic when cursor on demand budget is missing`() {
        let (store, controller) = self.makeController(
            suiteName: "StatusItemExtraUsageMetricTests-missing-budget",
            provider: .cursor)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 72, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .cursor)
        store._setErrorForTesting(nil, provider: .cursor)

        let window = controller.menuBarMetricWindow(for: .cursor, snapshot: snapshot)

        #expect(window?.usedPercent == 72)
    }

    @Test
    func `menu bar extra usage preference shows currency spend text for cursor when provider cost exists`() {
        let (store, controller) = self.makeController(
            suiteName: "StatusItemExtraUsageMetricTests-cursor-spend-text",
            provider: .cursor)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 72, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            providerCost: ProviderCostSnapshot(
                used: 12.34,
                limit: 100,
                currencyCode: "USD",
                updatedAt: Date()),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .cursor)
        store._setErrorForTesting(nil, provider: .cursor)

        let displayText = controller.menuBarDisplayText(for: .cursor, snapshot: snapshot)

        #expect(displayText == "$12.34")
    }

    @Test
    func `menu bar extra usage preference shows currency spend text for claude when provider cost exists`() {
        let (store, controller) = self.makeController(
            suiteName: "StatusItemExtraUsageMetricTests-claude-spend-text",
            provider: .claude)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            providerCost: ProviderCostSnapshot(
                used: 88.8,
                limit: 200,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Date()),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let displayText = controller.menuBarDisplayText(for: .claude, snapshot: snapshot)

        #expect(displayText == "$88.80")
    }

    @Test
    func `menu bar extra usage preference falls back to existing percent text when provider cost is unavailable`() {
        let (store, controller) = self.makeController(
            suiteName: "StatusItemExtraUsageMetricTests-fallback-percent",
            provider: .cursor)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 72, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .cursor)
        store._setErrorForTesting(nil, provider: .cursor)

        let displayText = controller.menuBarDisplayText(for: .cursor, snapshot: snapshot)

        #expect(displayText == "72%")
    }

    private func makeCursorController(suiteName: String) -> (UsageStore, StatusItemController) {
        self.makeController(suiteName: suiteName, provider: .cursor)
    }

    private func makeController(suiteName: String, provider: UsageProvider) -> (UsageStore, StatusItemController) {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = provider
        settings.menuBarDisplayMode = .percent
        settings.usageBarsShowUsed = true
        settings.setMenuBarMetricPreference(.extraUsage, for: provider)

        let registry = ProviderRegistry.shared
        if let metadata = registry.metadata[provider] {
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: true)
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
        return (store, controller)
    }
}
