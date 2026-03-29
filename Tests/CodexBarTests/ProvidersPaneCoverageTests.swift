import CodexBarCore
import Foundation
import SwiftUI
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
            "Automatic",
            "Primary (API key limit)",
        ])
    }

    @Test
    func `cursor menu bar metric picker omits tertiary api lane when snapshot has no api metric`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-cursor-no-tertiary-picker")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)

        let picker = pane._test_menuBarMetricPicker(for: .cursor)
        let ids = picker?.options.map(\.id) ?? []
        #expect(!ids.contains(MenuBarMetricPreference.tertiary.rawValue))
    }

    @Test
    func `cursor menu bar metric picker includes tertiary api lane when snapshot has api metric`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-cursor-tertiary-picker")
        let store = Self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 12, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 34, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                tertiary: RateWindow(usedPercent: 56, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                updatedAt: Date()),
            provider: .cursor)
        let pane = ProvidersPane(settings: settings, store: store)

        let picker = pane._test_menuBarMetricPicker(for: .cursor)
        let ids = picker?.options.map(\.id) ?? []
        #expect(ids.contains(MenuBarMetricPreference.tertiary.rawValue))
        let tertiaryOption = picker?.options.first { $0.id == MenuBarMetricPreference.tertiary.rawValue }
        #expect(tertiaryOption?.title == "Tertiary (API)")
    }

    @Test
    func `gemini menu bar metric picker omits tertiary lane`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-gemini-no-tertiary-picker")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)

        let picker = pane._test_menuBarMetricPicker(for: .gemini)
        let ids = picker?.options.map(\.id) ?? []
        #expect(!ids.contains(MenuBarMetricPreference.tertiary.rawValue))
    }

    @Test
    func `provider detail plan row formats open router as balance`() {
        let row = ProviderDetailView<EmptyView>.planRow(provider: .openrouter, planText: "Balance: $4.61")

        #expect(row?.label == "Balance")
        #expect(row?.value == "$4.61")
    }

    @Test
    func `provider detail plan row keeps plan label for non open router`() {
        let row = ProviderDetailView<EmptyView>.planRow(provider: .codex, planText: "Pro")

        #expect(row?.label == "Plan")
        #expect(row?.value == "Pro")
    }

    @Test
    func `codex providers pane uses managed account fallback instead of ambient account`() throws {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-codex-managed-fallback")
        let ambientHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: ambientHome)
            try? FileManager.default.removeItem(at: managedHome)
        }

        try Self.writeCodexAuthFile(homeURL: ambientHome, email: "ambient@example.com", plan: "plus")
        try Self.writeCodexAuthFile(homeURL: managedHome, email: "managed@example.com", plan: "enterprise")
        let managedAccountID = UUID()
        settings.codexActiveSource = .managedAccount(id: managedAccountID)
        settings._test_activeManagedCodexAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)

        let store = UsageStore(
            fetcher: UsageFetcher(environment: ["CODEX_HOME": ambientHome.path]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 34, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                updatedAt: Date(),
                identity: nil),
            provider: .codex)

        let pane = ProvidersPane(settings: settings, store: store)
        let model = pane._test_menuCardModel(for: .codex)

        #expect(model.email == "managed@example.com")
        #expect(model.planText == "Enterprise")
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

    private static func writeCodexAuthFile(homeURL: URL, email: String, plan: String) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let auth = [
            "tokens": [
                "accessToken": "access-token",
                "refreshToken": "refresh-token",
                "idToken": Self.fakeJWT(email: email, plan: plan),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
        ])) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
    }
}
