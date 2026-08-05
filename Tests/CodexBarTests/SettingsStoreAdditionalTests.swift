import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SettingsStoreAdditionalTests {
    @Test
    func `typed provider config bindings normalize every standard field`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-provider-config-bindings")

        let fields: [(ProviderConfigStringField, String)] = [
            (.apiKey, "api"),
            (.secretKey, "secret"),
            (.region, "region"),
            (.endpoint, "https://example.test"),
            (.workspace, "workspace"),
            (.cookieHeader, "session=fixture"),
        ]
        for (field, value) in fields {
            settings[providerConfig: .groq, field: field] = "  \(value)  "
            #expect(settings[providerConfig: .groq, field: field] == value)
        }

        let binding = settings.providerConfigBinding(provider: .openai, field: .secretWorkspace(logField: "projectID"))
        binding.wrappedValue = "  project  "
        #expect(binding.wrappedValue == "project")

        let cookieSource = settings.providerCookieSourceBinding(provider: .groq, fallback: .auto)
        #expect(cookieSource.wrappedValue == .auto)
        cookieSource.wrappedValue = .manual
        #expect(cookieSource.wrappedValue == .manual)

        settings[providerConfig: .groq, field: .apiKey] = "   "
        #expect(settings.providerConfig(for: .groq)?.apiKey == nil)
    }

    @Test
    @MainActor
    func `antigravity two pool migration preserves released metric meaning`() {
        let primaryDefaults = UserDefaults(suiteName: #function + ".primary")!
        primaryDefaults.removePersistentDomain(forName: #function + ".primary")
        primaryDefaults.set(
            [UsageProvider.antigravity.rawValue: MenuBarMetricPreference.primary.rawValue],
            forKey: "menuBarMetricPreferences")

        let primarySettings = SettingsStore(userDefaults: primaryDefaults)

        #expect(primarySettings.menuBarMetricPreference(for: .antigravity) == .secondary)
        #expect(primaryDefaults.bool(forKey: "antigravityTwoPoolMetricPreferenceMigrated"))

        let secondaryDefaults = UserDefaults(suiteName: #function + ".secondary")!
        secondaryDefaults.removePersistentDomain(forName: #function + ".secondary")
        secondaryDefaults.set(
            [UsageProvider.antigravity.rawValue: MenuBarMetricPreference.secondary.rawValue],
            forKey: "menuBarMetricPreferences")

        let secondarySettings = SettingsStore(userDefaults: secondaryDefaults)

        #expect(secondarySettings.menuBarMetricPreference(for: .antigravity) == .primary)

        let reloadedSettings = SettingsStore(userDefaults: secondaryDefaults)
        #expect(reloadedSettings.menuBarMetricPreference(for: .antigravity) == .primary)

        let tertiaryDefaults = UserDefaults(suiteName: #function + ".tertiary")!
        tertiaryDefaults.removePersistentDomain(forName: #function + ".tertiary")
        tertiaryDefaults.set(
            [UsageProvider.antigravity.rawValue: MenuBarMetricPreference.tertiary.rawValue],
            forKey: "menuBarMetricPreferences")

        let tertiarySettings = SettingsStore(userDefaults: tertiaryDefaults)

        #expect(tertiarySettings.menuBarMetricPreference(for: .antigravity) == .primary)

        let migratedDefaults = UserDefaults(suiteName: #function + ".migrated")!
        migratedDefaults.removePersistentDomain(forName: #function + ".migrated")
        migratedDefaults.set(
            [UsageProvider.antigravity.rawValue: MenuBarMetricPreference.primary.rawValue],
            forKey: "menuBarMetricPreferences")
        migratedDefaults.set(true, forKey: "antigravityTwoPoolMetricPreferenceMigrated")

        let migratedSettings = SettingsStore(userDefaults: migratedDefaults)

        #expect(migratedSettings.menuBarMetricPreference(for: .antigravity) == .primary)
    }

    @Test
    func `menu bar metric preference handles zai and average`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-metric")

        #expect(settings.menuBarMetricPreference(for: .zai) == .automatic)

        settings.setMenuBarMetricPreference(.average, for: .zai)
        #expect(settings.menuBarMetricPreference(for: .zai) == .automatic)

        settings.setMenuBarMetricPreference(.secondary, for: .zai)
        #expect(settings.menuBarMetricPreference(for: .zai) == .secondary)

        settings.setMenuBarMetricPreference(.tertiary, for: .zai)
        #expect(settings.menuBarMetricPreference(for: .zai) == .automatic)
        #expect(settings.menuBarMetricPreference(for: .zai, snapshot: nil) == .automatic)
        #expect(settings.menuBarMetricSupportsTertiary(for: .zai, snapshot: nil) == false)

        settings.setMenuBarMetricPreference(.average, for: .codex)
        #expect(settings.menuBarMetricPreference(for: .codex) == .automatic)

        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .codex)
        #expect(settings.menuBarMetricPreference(for: .codex) == .primaryAndSecondary)
        #expect(settings.menuBarMetricSupportsPrimaryAndSecondary(for: .codex))

        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .claude)
        #expect(settings.menuBarMetricPreference(for: .claude) == .primaryAndSecondary)
        #expect(settings.menuBarMetricSupportsPrimaryAndSecondary(for: .claude))

        settings.setMenuBarMetricPreference(.monthlyPlan, for: .codex)
        #expect(settings.menuBarMetricPreference(for: .codex) == .automatic)

        settings.menuBarMetricPreferencesRaw[UsageProvider.codex.rawValue] = MenuBarMetricPreference.monthlyPlan
            .rawValue
        #expect(settings.menuBarMetricPreference(for: .codex) == .automatic)

        settings.setMenuBarMetricPreference(.average, for: .gemini)
        #expect(settings.menuBarMetricPreference(for: .gemini) == .average)

        settings.setMenuBarMetricPreference(.tertiary, for: .codex)
        #expect(settings.menuBarMetricPreference(for: .codex) == .automatic)

        settings.setMenuBarMetricPreference(.tertiary, for: .cursor)
        #expect(settings.menuBarMetricPreference(for: .cursor) == .tertiary)
        #expect(settings.menuBarMetricPreference(for: .cursor, snapshot: nil) == .automatic)
        #expect(settings.menuBarMetricSupportsTertiary(for: .cursor, snapshot: nil) == false)

        settings.setMenuBarMetricPreference(.extraUsage, for: .cursor)
        #expect(settings.menuBarMetricPreference(for: .cursor) == .extraUsage)
        #expect(settings.menuBarMetricPreference(for: .cursor, snapshot: nil) == .automatic)
        #expect(settings.menuBarMetricSupportsExtraUsage(for: .cursor, snapshot: nil) == false)

        settings.setMenuBarMetricPreference(.extraUsage, for: .claude)
        #expect(settings.menuBarMetricPreference(for: .claude) == .extraUsage)
        #expect(settings.menuBarMetricPreference(for: .claude, snapshot: nil) == .automatic)
        #expect(settings.menuBarMetricSupportsExtraUsage(for: .claude, snapshot: nil) == false)

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

        settings.setMenuBarMetricPreference(.extraUsage, for: .openrouter)
        #expect(settings.menuBarMetricPreference(for: .openrouter) == .automatic)
    }

    @Test
    func `menu bar metric preference restricts mistral to payg or monthly plan`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-mistral-metric")

        settings.setMenuBarMetricPreference(.monthlyPlan, for: .mistral)
        #expect(settings.menuBarMetricPreference(for: .mistral) == .monthlyPlan)

        settings.setMenuBarMetricPreference(.secondary, for: .mistral)
        #expect(settings.menuBarMetricPreference(for: .mistral) == .automatic)
    }

    @Test
    func `menu bar metric preference restricts text only balance providers to automatic`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-text-only-metric")

        for provider in [UsageProvider.deepseek, .poe] {
            settings.setMenuBarMetricPreference(.primary, for: provider)
            #expect(settings.menuBarMetricPreference(for: provider) == .automatic)

            settings.setMenuBarMetricPreference(.secondary, for: provider)
            #expect(settings.menuBarMetricPreference(for: provider) == .automatic)
        }
    }

    @Test
    func `menu bar metric capability membership preserves every provider verdict`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-menu-metric-capabilities")
        let standard: Set<MenuBarMetricPreference> = [.automatic, .primary, .secondary]
        let overrides: [UsageProvider: Set<MenuBarMetricPreference>] = [
            .codex: standard.union([.primaryAndSecondary]),
            .claude: standard.union([.primaryAndSecondary, .extraUsage]),
            .cursor: standard.union([.tertiary, .extraUsage]),
            .gemini: standard.union([.average]),
            .perplexity: standard.union([.tertiary]),
            .mistral: [.automatic, .monthlyPlan],
            .openrouter: [.automatic, .primary],
            .deepseek: [.automatic],
            .deepinfra: [.automatic],
            .moonshot: [.automatic],
            .poe: [.automatic],
        ]

        for provider in UsageProvider.allCases {
            let supported = overrides[provider] ?? standard
            for preference in MenuBarMetricPreference.allCases {
                settings.setMenuBarMetricPreference(preference, for: provider)
                let expected = supported.contains(preference) ? preference : .automatic
                #expect(
                    settings.menuBarMetricPreference(for: provider) == expected,
                    "Unexpected \(preference.rawValue) verdict for \(provider.rawValue).")
            }
        }
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
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }
}
