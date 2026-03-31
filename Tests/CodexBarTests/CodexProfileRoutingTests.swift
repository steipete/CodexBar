import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexProfileRoutingTests {
    @Test
    func `provider registry routes codex through selected local profile`() throws {
        let settings = Self.makeSettingsStore(suite: "CodexProfileRoutingTests-env")
        let profileURL = URL(fileURLWithPath: "/tmp/codex-profile-plus-b.json")
        settings._test_codexProfiles = [
            DiscoveredCodexProfile(
                alias: "plus-a",
                fileURL: URL(fileURLWithPath: "/tmp/codex-profile-plus-a.json"),
                accountEmail: "plus-a@example.com",
                accountID: "acct-a",
                plan: "plus",
                isActiveInCodex: true),
            DiscoveredCodexProfile(
                alias: "plus-b",
                fileURL: profileURL,
                accountEmail: "plus-b@example.com",
                accountID: "acct-b",
                plan: "plus",
                isActiveInCodex: false),
        ]
        settings.selectCodexProfile(path: profileURL.path)

        let env = ProviderRegistry.makeEnvironment(
            base: [:],
            provider: .codex,
            settings: settings,
            tokenOverride: nil)

        #expect(env[CodexProfileExecutionEnvironment.authFileOverrideKey] == profileURL.standardizedFileURL.path)
        #expect(settings.selectedCodexProfileEmail() == "plus-b@example.com")
    }

    @Test
    func `missing selected local profile fails closed for openai web refresh`() async throws {
        let settings = Self.makeSettingsStore(suite: "CodexProfileRoutingTests-openai-fail-closed")
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .auto
        Self.enableOnlyCodex(settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings._test_codexProfiles = [
            DiscoveredCodexProfile(
                alias: "plus-a",
                fileURL: URL(fileURLWithPath: "/tmp/codex-profile-plus-a.json"),
                accountEmail: "plus-a@example.com",
                accountID: "acct-a",
                plan: "plus",
                isActiveInCodex: true),
        ]
        settings.selectCodexProfile(path: "/tmp/codex-profile-missing.json")

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        await store.refreshOpenAIDashboardIfNeeded(force: true)

        #expect(settings.codexSettingsSnapshot(tokenOverride: nil).selectedProfileUnavailable)
        #expect(store.openAIDashboard == nil)
        #expect(store.lastOpenAIDashboardError?.contains("selected local Codex profile is unavailable") == true)
    }

    @Test
    func `settings section exposes local profiles and selecting one switches codex back to live system`() async throws {
        let settings = Self.makeSettingsStore(suite: "CodexProfileRoutingTests-pane")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        settings._test_activeManagedCodexAccount = managedAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())

        let profileURL = URL(fileURLWithPath: "/tmp/codex-profile-plus-b.json")
        settings._test_codexProfiles = [
            DiscoveredCodexProfile(
                alias: "plus-a",
                fileURL: URL(fileURLWithPath: "/tmp/codex-profile-plus-a.json"),
                accountEmail: "plus-a@example.com",
                accountID: "acct-a",
                plan: "plus",
                isActiveInCodex: true),
            DiscoveredCodexProfile(
                alias: "plus-b",
                fileURL: profileURL,
                accountEmail: "plus-b@example.com",
                accountID: "acct-b",
                plan: "plus",
                isActiveInCodex: false),
        ]

        let pane = ProvidersPane(settings: settings, store: store)
        let initialState = try #require(pane._test_codexAccountsSectionState())
        #expect(initialState.localProfiles.map(\.title) == ["plus-a", "plus-b"])
        #expect(initialState.localProfiles.map(\.subtitle) == ["plus-a@example.com", "plus-b@example.com"])
        #expect(initialState.localProfiles.contains(where: { $0.title == "plus-a" && $0.isLive }))

        await pane._test_selectCodexLocalProfile(path: profileURL.path)

        #expect(settings.codexActiveSource == .liveSystem)
        #expect(settings.selectedCodexProfile()?.alias == "plus-b")
        let updatedState = try #require(pane._test_codexAccountsSectionState())
        #expect(updatedState.localProfiles.contains(where: { $0.title == "plus-b" && $0.isDisplayed }))
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

    private static func enableOnlyCodex(_ settings: SettingsStore) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
    }
}
