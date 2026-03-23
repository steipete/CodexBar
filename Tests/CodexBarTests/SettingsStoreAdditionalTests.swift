import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SettingsStoreAdditionalTests {
    @Test
    func `menu bar metric preference handles zai and average`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-metric")

        settings.setMenuBarMetricPreference(.average, for: .zai)
        #expect(settings.menuBarMetricPreference(for: .zai) == .primary)

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
    func `removing add-on preserves default account selection index`() throws {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-remove-preserves-default")

        settings.addTokenAccount(provider: .codex, label: "Work", token: "/tmp/codex-work")
        settings.addTokenAccount(provider: .codex, label: "Home", token: "/tmp/codex-home")
        settings.setActiveTokenAccountIndex(-1, for: .codex)
        #expect(settings.tokenAccountsData(for: .codex)?.activeIndex == -1)

        let toRemove = try #require(settings.tokenAccounts(for: .codex).first)
        settings.removeTokenAccount(provider: .codex, accountID: toRemove.id)

        #expect(settings.tokenAccounts(for: .codex).count == 1)
        #expect(settings.tokenAccountsData(for: .codex)?.activeIndex == -1)
    }

    @Test
    func `removing earlier account preserves active account by identity`() throws {
        // [A, B, C] active=B (index 1). Delete A → [B, C], active must stay on B (index 0).
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-remove-preserves-identity")

        settings.addTokenAccount(provider: .codex, label: "A", token: "/tmp/codex-a")
        settings.addTokenAccount(provider: .codex, label: "B", token: "/tmp/codex-b")
        settings.addTokenAccount(provider: .codex, label: "C", token: "/tmp/codex-c")

        let accounts = settings.tokenAccounts(for: .codex)
        let accountA = try #require(accounts.first { $0.label == "A" })
        let accountB = try #require(accounts.first { $0.label == "B" })

        // Activate B (index 1).
        settings.setActiveTokenAccountIndex(1, for: .codex)
        #expect(settings.tokenAccountsData(for: .codex)?.activeIndex == 1)

        // Delete A (index 0, which is before the active account).
        settings.removeTokenAccount(provider: .codex, accountID: accountA.id)

        let remaining = settings.tokenAccounts(for: .codex)
        #expect(remaining.count == 2)
        // Active account must still be B, now at index 0.
        let newIndex = try #require(settings.tokenAccountsData(for: .codex)?.activeIndex)
        #expect(newIndex == 0)
        #expect(remaining[newIndex].id == accountB.id)
    }

    @Test
    func `removing active account clamps to nearest remaining account`() throws {
        // [A, B, C] active=B (index 1). Delete B → [A, C], active clamps to index 1 (C).
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-remove-active-clamps")

        settings.addTokenAccount(provider: .codex, label: "A", token: "/tmp/codex-a")
        settings.addTokenAccount(provider: .codex, label: "B", token: "/tmp/codex-b")
        settings.addTokenAccount(provider: .codex, label: "C", token: "/tmp/codex-c")

        let accountB = try #require(settings.tokenAccounts(for: .codex).first { $0.label == "B" })

        settings.setActiveTokenAccountIndex(1, for: .codex)
        settings.removeTokenAccount(provider: .codex, accountID: accountB.id)

        let remaining = settings.tokenAccounts(for: .codex)
        #expect(remaining.count == 2)
        // B was deleted; activeIndex should clamp (1 is still valid → points to C).
        let newIndex = try #require(settings.tokenAccountsData(for: .codex)?.activeIndex)
        #expect(newIndex == 1)
        #expect(remaining[newIndex].label == "C")
    }

    @Test
    func `claude default token account active follows stored primary selection`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-claude-default-active")

        settings.addTokenAccount(provider: .claude, label: "Work", token: "token-1")
        settings.setActiveTokenAccountIndex(-1, for: .claude)
        #expect(settings.isDefaultTokenAccountActive(for: .claude))
        #expect(settings.displayTokenAccountActiveIndex(for: .claude) == -1)

        settings.setActiveTokenAccountIndex(0, for: .claude)
        #expect(!settings.isDefaultTokenAccountActive(for: .claude))
        #expect(settings.displayTokenAccountActiveIndex(for: .claude) == 0)
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
