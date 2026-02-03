import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct SettingsStoreCoverageTests {
    @Test
    func providerOrderingAndCaching() throws {
        let suite = "SettingsStoreCoverageTests-ordering"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .zai),
            ProviderConfig(id: .codex),
            ProviderConfig(id: .claude),
        ])
        try configStore.save(config)
        let settings = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        let ordered = settings.orderedProviders()
        let cached = settings.orderedProviders()

        #expect(ordered == cached)
        #expect(ordered.first == .zai)
        #expect(ordered.contains(.minimax))

        settings.moveProvider(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(settings.orderedProviders() != ordered)

        let metadata = ProviderRegistry.shared.metadata
        try settings.setProviderEnabled(provider: .codex, metadata: #require(metadata[.codex]), enabled: true)
        try settings.setProviderEnabled(provider: .claude, metadata: #require(metadata[.claude]), enabled: false)
        let enabled = settings.enabledProvidersOrdered(metadataByProvider: metadata)
        #expect(enabled.contains(.codex))
    }

    @Test
    func menuBarMetricPreferencesAndDisplayModes() {
        let settings = Self.makeSettingsStore()

        settings.setMenuBarMetricPreference(.average, for: .codex)
        #expect(settings.menuBarMetricPreference(for: .codex) == .automatic)

        settings.setMenuBarMetricPreference(.average, for: .gemini)
        #expect(settings.menuBarMetricPreference(for: .gemini) == .average)
        #expect(settings.menuBarMetricSupportsAverage(for: .gemini))

        settings.setMenuBarMetricPreference(.secondary, for: .zai)
        #expect(settings.menuBarMetricPreference(for: .zai) == .primary)

        settings.menuBarDisplayMode = .pace
        #expect(settings.menuBarDisplayMode == .pace)

        settings.resetTimesShowAbsolute = true
        #expect(settings.resetTimeDisplayStyle == .absolute)
    }

    @Test
    func tokenAccountMutationsApplySideEffects() {
        let settings = Self.makeSettingsStore()

        settings.addTokenAccount(provider: .claude, label: "Primary", token: "token")
        #expect(settings.tokenAccounts(for: .claude).count == 1)
        #expect(settings.claudeCookieSource == .manual)

        let account = settings.selectedTokenAccount(for: .claude)
        #expect(account != nil)

        settings.setActiveTokenAccountIndex(10, for: .claude)
        #expect(settings.selectedTokenAccount(for: .claude)?.id == account?.id)

        if let id = account?.id {
            settings.removeTokenAccount(provider: .claude, accountID: id)
        }
        #expect(settings.tokenAccounts(for: .claude).isEmpty)

        settings.reloadTokenAccounts()
    }

    @Test
    func tokenCostUsageSourceDetection() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "token-cost-\(UUID().uuidString)",
            isDirectory: true)
        let codexRoot = root.appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let codexFile = codexRoot.appendingPathComponent("usage.jsonl")
        fileManager.createFile(atPath: codexFile.path, contents: Data("{}".utf8))

        #expect(SettingsStore.hasAnyTokenCostUsageSources(
            env: ["CODEX_HOME": root.path],
            fileManager: fileManager))

        let claudeRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "claude-\(UUID().uuidString)",
            isDirectory: true)
        let claudeProjects = claudeRoot.appendingPathComponent("projects", isDirectory: true)
        try fileManager.createDirectory(at: claudeProjects, withIntermediateDirectories: true)
        let claudeFile = claudeProjects.appendingPathComponent("usage.jsonl")
        fileManager.createFile(atPath: claudeFile.path, contents: Data("{}".utf8))

        #expect(SettingsStore.hasAnyTokenCostUsageSources(
            env: ["CLAUDE_CONFIG_DIR": claudeRoot.path],
            fileManager: fileManager))
    }

    @Test
    func ensureTokenLoadersExecute() {
        let settings = Self.makeSettingsStore()

        settings.ensureZaiAPITokenLoaded()
        settings.ensureSyntheticAPITokenLoaded()
        settings.ensureCodexCookieLoaded()
        settings.ensureClaudeCookieLoaded()
        settings.ensureCursorCookieLoaded()
        settings.ensureOpenCodeCookieLoaded()
        settings.ensureFactoryCookieLoaded()
        settings.ensureMiniMaxCookieLoaded()
        settings.ensureMiniMaxAPITokenLoaded()
        settings.ensureKimiAuthTokenLoaded()
        settings.ensureKimiK2APITokenLoaded()
        settings.ensureAugmentCookieLoaded()
        settings.ensureAmpCookieLoaded()
        settings.ensureCopilotAPITokenLoaded()
        settings.ensureTokenAccountsLoaded()

        #expect(settings.zaiAPIToken.isEmpty)
        #expect(settings.syntheticAPIToken.isEmpty)
    }

    @Test
    func keychainDisableForcesManualCookieSources() throws {
        let suite = "SettingsStoreCoverageTests-keychain"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)

        settings.codexCookieSource = .auto
        settings.claudeCookieSource = .auto
        settings.kimiCookieSource = .off
        settings.debugDisableKeychainAccess = true

        #expect(settings.codexCookieSource == .manual)
        #expect(settings.claudeCookieSource == .manual)
        #expect(settings.kimiCookieSource == .off)
    }

    private static func makeSettingsStore(suiteName: String = "SettingsStoreCoverageTests") -> SettingsStore {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "debugDisableKeychainAccess")
        let configStore = testConfigStore(suiteName: suiteName)
        return Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
    }

    private static func makeSettingsStore(
        userDefaults: UserDefaults,
        configStore: CodexBarConfigStore) -> SettingsStore
    {
        SettingsStore(
            userDefaults: userDefaults,
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
