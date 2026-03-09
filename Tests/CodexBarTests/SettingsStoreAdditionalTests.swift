import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct SettingsStoreAdditionalTests {
    @Test
    func menuBarMetricPreferenceHandlesZaiAndAverage() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-metric")

        settings.setMenuBarMetricPreference(.average, for: .zai)
        #expect(settings.menuBarMetricPreference(for: .zai) == .primary)

        settings.setMenuBarMetricPreference(.average, for: .codex)
        #expect(settings.menuBarMetricPreference(for: .codex) == .automatic)

        settings.setMenuBarMetricPreference(.average, for: .gemini)
        #expect(settings.menuBarMetricPreference(for: .gemini) == .average)
    }

    @Test
    func menuBarMetricPreferenceRestrictsOpenRouterToAutomaticOrPrimary() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-openrouter-metric")

        settings.setMenuBarMetricPreference(.secondary, for: .openrouter)
        #expect(settings.menuBarMetricPreference(for: .openrouter) == .automatic)

        settings.setMenuBarMetricPreference(.average, for: .openrouter)
        #expect(settings.menuBarMetricPreference(for: .openrouter) == .automatic)

        settings.setMenuBarMetricPreference(.primary, for: .openrouter)
        #expect(settings.menuBarMetricPreference(for: .openrouter) == .primary)
    }

    @Test
    func minimaxAuthModeUsesStoredValues() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-minimax")
        settings.minimaxAPIToken = "sk-api-test-token"
        settings.minimaxCookieHeader = "cookie=value"

        #expect(settings.minimaxAuthMode(environment: [:]) == .apiToken)

        settings.minimaxAPIToken = ""
        #expect(settings.minimaxAuthMode(environment: [:]) == .cookie)
    }

    @Test
    func tokenAccountsSetManualCookieSourceWhenRequired() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-token-accounts")

        settings.addTokenAccount(provider: .claude, label: "Primary", token: "token-1")

        #expect(settings.tokenAccounts(for: .claude).count == 1)
        #expect(settings.claudeCookieSource == .manual)
    }

    @Test
    func ollamaTokenAccountsSetManualCookieSourceWhenRequired() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-ollama-token-accounts")

        settings.addTokenAccount(provider: .ollama, label: "Primary", token: "session=token-1")

        #expect(settings.tokenAccounts(for: .ollama).count == 1)
        #expect(settings.ollamaCookieSource == .manual)
    }

    @Test
    func detectsTokenCostUsageSourcesFromFilesystem() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        let jsonl = sessions.appendingPathComponent("usage.jsonl")
        try Data("{}".utf8).write(to: jsonl)
        defer { try? fm.removeItem(at: root) }

        let env = ["CODEX_HOME": root.path]

        #expect(SettingsStore.hasAnyTokenCostUsageSources(env: env, fileManager: fm))
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
}
