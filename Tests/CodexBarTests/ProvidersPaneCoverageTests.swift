import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct ProvidersPaneCoverageTests {
    @Test
    func `exercises providers pane views`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests")
        let store = Self.makeUsageStore(settings: settings)

        ProvidersPaneTestHarness.exercise(settings: settings, store: store)
    }

    @Test
    func `open router menu bar metric picker shows only automatic and primary`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-openrouter-picker")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)

        let picker = pane._test_menuBarMetricPicker(for: .openrouter)
        #expect(picker?.options.map(\.id) == [
            MenuBarMetricPreference.automatic.rawValue,
            MenuBarMetricPreference.primary.rawValue,
        ])
        #expect(picker?.options.map(\.title) == [
            AppStrings.tr("Automatic"),
            AppStrings.tr("Primary (API key limit)"),
        ])
    }

    @Test
    func `provider detail plan row formats open router as balance`() {
        let row = ProviderDetailView.planRow(provider: .openrouter, planText: "Balance: $4.61")

        #expect(row?.label == AppStrings.tr("Balance"))
        #expect(row?.value == "$4.61")
    }

    @Test
    func `provider detail plan row keeps plan label for non open router`() {
        let row = ProviderDetailView.planRow(provider: .codex, planText: "Pro")

        #expect(row?.label == AppStrings.tr("Plan"))
        #expect(row?.value == "Pro")
    }

    @Test
    func `provider subtitle follows selected language`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-language")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)

        AppStrings.withTestingLanguage(.simplifiedChinese) {
            #expect(pane.providerSubtitle(.codex).contains(AppStrings.tr("usage not fetched yet")))

            store._setErrorForTesting("boom", provider: .codex)
            #expect(pane.providerSubtitle(.codex).contains(AppStrings.tr("last fetch failed")))

            store._setErrorForTesting(nil, provider: .codex)
            store._setSnapshotForTesting(
                UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()),
                provider: .codex)
            #expect(pane.providerSubtitle(.codex).contains(AppStrings.tr("just now")))
        }
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
    }
}
