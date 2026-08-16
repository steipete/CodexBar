import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct CodexBusinessSwitcherTests {
    @Test
    func `switcher keeps quota indicator visible for the selected provider`() {
        let view = ProviderSwitcherView(
            providers: [.codex, .claude],
            selected: .provider(.codex),
            includesOverview: false,
            width: 180,
            showsIcons: true,
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            weeklyRemainingProvider: { _ in 50 },
            onSelect: { _ in })

        #expect(view._test_quotaIndicatorVisibility().allSatisfy { !$0.trackHidden && !$0.fillHidden })

        view.updateSelection(.provider(.claude))
        view.updateQuotaIndicators()

        #expect(view._test_quotaIndicatorVisibility().allSatisfy { !$0.trackHidden && !$0.fillHidden })
    }

    @Test
    func `codex switcher falls back to business monthly credit remaining`() throws {
        let suite = "CodexBusinessSwitcherTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true

        let registry = ProviderRegistry.shared
        if let metadata = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        store._setSnapshotForTesting(nil, provider: .codex)
        store.credits = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 27,
                limit: 100,
                remainingPercent: 73,
                resetsAt: nil,
                updatedAt: now))

        #expect(controller.switcherWeeklyRemaining(for: .codex) == 73)

        settings.usageBarsShowUsed = true
        #expect(controller.switcherWeeklyRemaining(for: .codex) == 27)

        settings.usageBarsShowUsed = false
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 12,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .codex)

        #expect(controller.switcherWeeklyRemaining(for: .codex) == 88)
    }
}
