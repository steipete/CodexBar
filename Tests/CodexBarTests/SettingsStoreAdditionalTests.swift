import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SettingsStoreAdditionalTests {
    @Test
    func `menu bar metric preference handles zai and average`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-metric")

        #expect(settings.menuBarMetricPreference(for: .zai) == .automatic)

        settings.setMenuBarMetricPreference(.average, for: .zai)
        #expect(settings.menuBarMetricPreference(for: .zai) == .automatic)

        settings.setMenuBarMetricPreference(.secondary, for: .zai)
        #expect(settings.menuBarMetricPreference(for: .zai) == .secondary)

        settings.setMenuBarMetricPreference(.tertiary, for: .zai)
        #expect(settings.menuBarMetricPreference(for: .zai) == .tertiary)
        #expect(settings.menuBarMetricPreference(for: .zai, snapshot: nil) == .automatic)
        #expect(settings.menuBarMetricSupportsTertiary(for: .zai, snapshot: nil) == false)

        settings.setMenuBarMetricPreference(.average, for: .codex)
        #expect(settings.menuBarMetricPreference(for: .codex) == .automatic)

        settings.setMenuBarMetricPreference(.average, for: .gemini)
        #expect(settings.menuBarMetricPreference(for: .gemini) == .average)

        settings.setMenuBarMetricPreference(.tertiary, for: .codex)
        #expect(settings.menuBarMetricPreference(for: .codex) == .automatic)

        settings.setMenuBarMetricPreference(.tertiary, for: .cursor)
        #expect(settings.menuBarMetricPreference(for: .cursor) == .tertiary)
        #expect(settings.menuBarMetricPreference(for: .cursor, snapshot: nil) == .automatic)
        #expect(settings.menuBarMetricSupportsTertiary(for: .cursor, snapshot: nil) == false)

        settings.setMenuBarMetricPreference(.tertiary, for: .perplexity)
        #expect(settings.menuBarMetricPreference(for: .perplexity) == .tertiary)
        #expect(settings.menuBarMetricPreference(for: .perplexity, snapshot: nil) == .tertiary)
        #expect(settings.menuBarMetricSupportsTertiary(for: .perplexity, snapshot: nil))

        settings.setMenuBarMetricPreference(.tertiary, for: .gemini)
        #expect(settings.menuBarMetricPreference(for: .gemini) == .automatic)
    }

    @Test
    func `menu bar metric preference restricts open router to automatic or primary`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-openrouter-metric")

        settings.setMenuBarMetricPreference(.secondary, for: .openrouter)
        #expect(settings.menuBarMetricPreference(for: .openrouter) == .automatic)

        settings.setMenuBarMetricPreference(.average, for: .openrouter)
        #expect(settings.menuBarMetricPreference(for: .openrouter) == .automatic)

        settings.setMenuBarMetricPreference(.primary, for: .openrouter)
        #expect(settings.menuBarMetricPreference(for: .openrouter) == .primary)

        settings.setMenuBarMetricPreference(.tertiary, for: .openrouter)
        #expect(settings.menuBarMetricPreference(for: .openrouter) == .automatic)
    }

    @Test
    func `minimax auth mode uses stored values`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-minimax")
        settings.minimaxAPIToken = "sk-api-test-token"
        settings.minimaxCookieHeader = "cookie=value"

        #expect(settings.minimaxAuthMode(environment: [:]) == .apiToken)

        settings.minimaxAPIToken = ""
        #expect(settings.minimaxAuthMode(environment: [:]) == .cookie)
    }

    @Test
    func `token accounts set manual cookie source when required`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-token-accounts")

        settings.addTokenAccount(provider: .claude, label: "Primary", token: "token-1")

        #expect(settings.tokenAccounts(for: .claude).count == 1)
        #expect(settings.claudeCookieSource == .manual)
    }

    @Test
    func `ollama token accounts set manual cookie source when required`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-ollama-token-accounts")

        settings.addTokenAccount(provider: .ollama, label: "Primary", token: "session=token-1")

        #expect(settings.tokenAccounts(for: .ollama).count == 1)
        #expect(settings.ollamaCookieSource == .manual)
    }

    @Test
    func `detects token cost usage sources from filesystem`() throws {
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
