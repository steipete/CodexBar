import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuScopedCodexRefreshTests {
    @Test
    func `scoped refresh reconciles usage after dashboard login expires`() async {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .auto
        self.enableOnlyCodex(settings)

        let account = AccountInfo(email: "test@example.com", plan: "pro")
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.accountInfoCache[.codex] = UsageStore.AccountInfoCacheEntry(
            account: account,
            configRevision: settings.configRevision,
            expiresAt: .distantFuture)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: account,
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)

        var providerRefreshes = 0
        store._test_providerRefreshOverride = { provider in
            #expect(provider == .codex)
            providerRefreshes += 1
        }
        store._test_tokenUsageRefreshOverride = { _, _ in }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            throw OpenAIDashboardFetcher.FetchError.loginRequired
        }
        store._test_openAIDashboardCookieImportOverride = { targetEmail, _, _, _, _ in
            OpenAIDashboardBrowserCookieImporter.ImportResult(
                sourceLabel: "Chrome",
                cookieCount: 2,
                signedInEmail: targetEmail,
                matchesCodexEmail: true)
        }

        await controller.performStoreRefresh(
            for: .codex,
            refreshOpenMenusWhenComplete: false,
            interaction: .userInitiated)

        #expect(store.openAIDashboardRequiresLogin)
        #expect(providerRefreshes == 2)
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuScopedCodexRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func enableOnlyCodex(_ settings: SettingsStore) {
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
    }
}
