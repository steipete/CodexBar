import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ProvidersPaneCoverageTests {
    @Test
    func `exercises providers pane views`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests")
        let store = Self.makeUsageStore(settings: settings)

        ProvidersPaneTestHarness.exercise(settings: settings, store: store)
    }

    @Test
    func `open router menu bar lane pickers limit lane choices`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-openrouter-picker")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)

        let pickers = pane._test_menuBarLanePickers(for: .openrouter)
        #expect(pickers.count == 2)
        #expect(pickers[0].options.map(\.id) == [
            MenuBarIconLane.automatic.rawValue,
            MenuBarIconLane.primary.rawValue,
        ])
        #expect(pickers[1].options.map(\.id) == [
            MenuBarIconLane.none.rawValue,
            MenuBarIconLane.automatic.rawValue,
            MenuBarIconLane.primary.rawValue,
        ])
    }

    @Test
    func `cursor menu bar top lane picker includes tertiary api lane`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-cursor-tertiary-picker")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)

        let pickers = pane._test_menuBarLanePickers(for: .cursor)
        #expect(pickers.count == 2)
        let topIds = pickers[0].options.map(\.id)
        #expect(topIds.contains(MenuBarIconLane.tertiary.rawValue))
        let tertiaryOption = pickers[0].options.first { $0.id == MenuBarIconLane.tertiary.rawValue }
        #expect(tertiaryOption?.title == "Tertiary (API)")
    }

    @Test
    func `gemini menu bar top lane picker omits tertiary lane`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-gemini-no-tertiary-picker")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)

        let pickers = pane._test_menuBarLanePickers(for: .gemini)
        let topIds = pickers[0].options.map(\.id)
        #expect(!topIds.contains(MenuBarIconLane.tertiary.rawValue))
    }

    @Test
    func `provider detail plan row formats open router as balance`() {
        let row = ProviderDetailView.planRow(provider: .openrouter, planText: "Balance: $4.61")

        #expect(row?.label == "Balance")
        #expect(row?.value == "$4.61")
    }

    @Test
    func `provider detail plan row keeps plan label for non open router`() {
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
