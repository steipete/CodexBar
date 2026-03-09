import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct ProvidersPaneCoverageTests {
    @Test
    func exercisesProvidersPaneViews() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests")
        let store = Self.makeUsageStore(settings: settings)

        ProvidersPaneTestHarness.exercise(settings: settings, store: store)
    }

    @Test
    func openRouterMenuBarMetricPicker_showsOnlyAutomaticAndPrimary() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-openrouter-picker")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)

        let picker = pane._test_menuBarMetricPicker(for: .openrouter)
        #expect(picker?.options.map(\.id) == [
            MenuBarMetricPreference.automatic.rawValue,
            MenuBarMetricPreference.primary.rawValue,
        ])
        #expect(picker?.options.map(\.title) == [
            "Automatic",
            "Primary (API key limit)",
        ])
    }

    @Test
    func providerDetailPlanRow_formatsOpenRouterAsBalance() {
        let row = ProviderDetailView.planRow(provider: .openrouter, planText: "Balance: $4.61")

        #expect(row?.label == "Balance")
        #expect(row?.value == "$4.61")
    }

    @Test
    func providerDetailPlanRow_keepsPlanLabelForNonOpenRouter() {
        let row = ProviderDetailView.planRow(provider: .codex, planText: "Pro")

        #expect(row?.label == "Plan")
        #expect(row?.value == "Pro")
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
