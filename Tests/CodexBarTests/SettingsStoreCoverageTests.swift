import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SettingsStoreCoverageTests {
    @Test
    func `provider ordering and caching`() throws {
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
    func `disabling selected provider clears menu selection`() throws {
        let settings = Self.makeSettingsStore()
        let metadata = ProviderRegistry.shared.metadata

        try settings.setProviderEnabled(provider: .codex, metadata: #require(metadata[.codex]), enabled: true)
        try settings.setProviderEnabled(provider: .claude, metadata: #require(metadata[.claude]), enabled: true)
        settings.selectedMenuProvider = .claude

        try settings.setProviderEnabled(provider: .claude, metadata: #require(metadata[.claude]), enabled: false)

        #expect(settings.selectedMenuProvider == nil)
        #expect(settings.enabledProvidersOrdered(metadataByProvider: metadata) == [.codex])
    }

    @Test
    func `menu bar metric preferences and display modes`() {
        let settings = Self.makeSettingsStore()

        settings.setMenuBarMetricPreference(.average, for: .codex)
        #expect(settings.menuBarMetricPreference(for: .codex) == .automatic)

        settings.setMenuBarMetricPreference(.average, for: .gemini)
        #expect(settings.menuBarMetricPreference(for: .gemini) == .average)
        #expect(settings.menuBarMetricSupportsAverage(for: .gemini))

        settings.setMenuBarMetricPreference(.secondary, for: .zai)
        #expect(settings.menuBarMetricPreference(for: .zai) == .secondary)

        settings.menuBarDisplayMode = .pace
        #expect(settings.menuBarDisplayMode == .pace)
        #expect(settings.historicalTrackingEnabled == false)
        settings.historicalTrackingEnabled = true
        #expect(settings.historicalTrackingEnabled == true)

        settings.resetTimesShowAbsolute = true
        #expect(settings.resetTimeDisplayStyle == .absolute)
    }

    @Test
    func `minimax settings snapshot uses selected token account as manual cookie`() {
        let settings = Self.makeSettingsStore(suiteName: "SettingsStoreCoverageTests-minimax-token-account")
        settings.minimaxCookieSource = .auto
        settings.minimaxCookieHeader = "HERTZ-SESSION=global"
        settings.addTokenAccount(provider: .minimax, label: "account", token: "HERTZ-SESSION=selected")

        let snapshot = settings.minimaxSettingsSnapshot(tokenOverride: nil)

        #expect(snapshot.cookieSource == .manual)
        #expect(snapshot.manualCookieHeader == "HERTZ-SESSION=selected")
    }

    @Test
    func `minimax settings snapshot falls back to global cookie without token accounts`() {
        let settings = Self.makeSettingsStore(suiteName: "SettingsStoreCoverageTests-minimax-global-cookie")
        settings.minimaxCookieSource = .auto
        settings.minimaxCookieHeader = "HERTZ-SESSION=global"

        let snapshot = settings.minimaxSettingsSnapshot(tokenOverride: nil)

        #expect(snapshot.cookieSource == .auto)
        #expect(snapshot.manualCookieHeader == "HERTZ-SESSION=global")
    }

    @Test
    func `copilot budget extras default off and persist in provider snapshot`() throws {
        let suite = "SettingsStoreCoverageTests-copilot-budget-extras"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let initial = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(initial.copilotBudgetExtrasEnabled == false)
        #expect(initial.copilotSettingsSnapshot(tokenOverride: nil).budgetExtrasEnabled == false)

        initial.copilotBudgetExtrasEnabled = true

        let reloaded = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(reloaded.copilotBudgetExtrasEnabled)
        #expect(reloaded.copilotSettingsSnapshot(tokenOverride: nil).budgetExtrasEnabled)
    }

    @Test
    func `multi account menu layout persists and bridges legacy show all token accounts`() throws {
        let suite = "SettingsStoreCoverageTests-multi-account-layout"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let initial = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(initial.multiAccountMenuLayout == .segmented)

        initial.multiAccountMenuLayout = .stacked
        #expect(defaults.string(forKey: "multiAccountMenuLayout") == MultiAccountMenuLayout.stacked.rawValue)
        #expect(initial.showAllTokenAccountsInMenu)

        let reloaded = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(reloaded.multiAccountMenuLayout == .stacked)
        reloaded.showAllTokenAccountsInMenu = false
        #expect(reloaded.multiAccountMenuLayout == .segmented)
    }

    @Test
    func `legacy show all token accounts migrates to stacked layout`() throws {
        let suite = "SettingsStoreCoverageTests-legacy-token-account-layout"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "showAllTokenAccountsInMenu")
        let configStore = testConfigStore(suiteName: suite)

        let settings = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)

        #expect(settings.multiAccountMenuLayout == .stacked)
    }

    @Test
    func `token account mutations apply side effects`() {
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
    func `token account update preserves identity and selection`() throws {
        let settings = Self.makeSettingsStore()

        settings.addTokenAccount(provider: .copilot, label: "Primary", token: "token-1")
        settings.addTokenAccount(provider: .copilot, label: "Secondary", token: "token-2")
        settings.setActiveTokenAccountIndex(0, for: .copilot)

        let original = try #require(settings.selectedTokenAccount(for: .copilot))
        settings.updateTokenAccount(
            provider: .copilot,
            accountID: original.id,
            label: "Primary (Pro)",
            token: "token-1b")

        let updated = try #require(settings.selectedTokenAccount(for: .copilot))
        #expect(updated.id == original.id)
        #expect(updated.label == "Primary (Pro)")
        #expect(updated.token == "token-1b")
        #expect(settings.tokenAccounts(for: .copilot).count == 2)
    }

    @Test
    func `zai token account update preserves team metadata`() throws {
        let settings = Self.makeSettingsStore()

        settings.addTokenAccount(
            provider: .zai,
            label: "Team",
            token: "token-1",
            usageScope: "team",
            organizationID: "org-team",
            workspaceID: "proj-team")

        let original = try #require(settings.selectedTokenAccount(for: .zai))
        settings.updateTokenAccount(
            provider: .zai,
            accountID: original.id,
            label: "Team Updated",
            token: "token-2")

        let updated = try #require(settings.selectedTokenAccount(for: .zai))
        #expect(updated.usageScope == "team")
        #expect(updated.organizationID == "org-team")
        #expect(updated.workspaceID == "proj-team")
    }

    @Test
    func `copilot token accounts clear legacy api key fallback`() throws {
        let settings = Self.makeSettingsStore()
        settings.copilotAPIToken = "legacy-token"

        settings.addTokenAccount(provider: .copilot, label: "Primary", token: "token-1")

        #expect(settings.copilotAPIToken.isEmpty)
        #expect(settings.copilotSettingsSnapshot(tokenOverride: nil).apiToken == "token-1")

        settings.copilotAPIToken = "legacy-token"
        let account = try #require(settings.selectedTokenAccount(for: .copilot))
        settings.removeTokenAccount(provider: .copilot, accountID: account.id)

        #expect(settings.tokenAccounts(for: .copilot).isEmpty)
        #expect(settings.copilotAPIToken.isEmpty)
        #expect(settings.copilotSettingsSnapshot(tokenOverride: nil).apiToken == nil)
    }

    @Test
    func `copilot settings snapshot carries selected account identifier`() {
        let settings = Self.makeSettingsStore()
        settings.addTokenAccount(
            provider: .copilot,
            label: "octocat (Pro)",
            token: "token-1",
            externalIdentifier: "github:user:123")

        let snapshot = settings.copilotSettingsSnapshot(tokenOverride: nil)

        #expect(snapshot.apiToken == "token-1")
        #expect(snapshot.selectedAccountExternalIdentifier == "github:user:123")
    }

    @Test
    func `copilot enterprise host persists in provider config`() throws {
        let suite = "SettingsStoreCoverageTests-copilot-enterprise-host"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let first = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)

        first.copilotEnterpriseHost = "https://octocorp.ghe.com/login"
        #expect(first.copilotEnterpriseHost == "https://octocorp.ghe.com/login")
        #expect(first.copilotSettingsSnapshot(tokenOverride: nil).enterpriseHost == "octocorp.ghe.com")

        let second = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(second.copilotEnterpriseHost == "https://octocorp.ghe.com/login")

        second.copilotEnterpriseHost = "github.com"
        #expect(second.copilotEnterpriseHost == "github.com")
        #expect(second.copilotSettingsSnapshot(tokenOverride: nil).enterpriseHost == nil)
    }

    @Test
    func `removing another token account preserves active selection`() throws {
        let settings = Self.makeSettingsStore()

        settings.addTokenAccount(provider: .copilot, label: "A", token: "token-a")
        settings.addTokenAccount(provider: .copilot, label: "B", token: "token-b")
        settings.addTokenAccount(provider: .copilot, label: "C", token: "token-c")
        settings.setActiveTokenAccountIndex(1, for: .copilot)

        let activeBefore = try #require(settings.selectedTokenAccount(for: .copilot))
        let accountToRemove = try #require(settings.tokenAccounts(for: .copilot).first)
        settings.removeTokenAccount(provider: .copilot, accountID: accountToRemove.id)

        let activeAfter = try #require(settings.selectedTokenAccount(for: .copilot))
        #expect(activeAfter.id == activeBefore.id)
        #expect(activeAfter.label == "B")
        #expect(settings.tokenAccounts(for: .copilot).map(\.label) == ["B", "C"])
    }

    @Test
    func `claude snapshot uses OAuth routing for OAuth token accounts`() {
        let settings = Self.makeSettingsStore()
        settings.addTokenAccount(provider: .claude, label: "OAuth", token: "Bearer sk-ant-oat-account-token")

        let snapshot = settings.claudeSettingsSnapshot(tokenOverride: nil)

        #expect(snapshot.usageDataSource == .auto)
        #expect(snapshot.cookieSource == .off)
        #expect(snapshot.manualCookieHeader?.isEmpty == true)
    }

    @Test
    func `claude snapshot uses manual cookie routing for session key accounts`() {
        let settings = Self.makeSettingsStore()
        settings.addTokenAccount(provider: .claude, label: "Cookie", token: "sk-ant-session-token")

        let snapshot = settings.claudeSettingsSnapshot(tokenOverride: nil)

        #expect(snapshot.usageDataSource == .auto)
        #expect(snapshot.cookieSource == .manual)
        #expect(snapshot.manualCookieHeader == "sessionKey=sk-ant-session-token")
    }

    @Test
    func `claude snapshot normalizes config manual cookie input through shared route`() {
        let settings = Self.makeSettingsStore()
        settings.claudeCookieSource = .manual
        settings.claudeCookieHeader = "Cookie: sessionKey=sk-ant-session-token; foo=bar"

        let snapshot = settings.claudeSettingsSnapshot(tokenOverride: nil)

        #expect(snapshot.usageDataSource == .auto)
        #expect(snapshot.cookieSource == .manual)
        #expect(snapshot.manualCookieHeader == "sessionKey=sk-ant-session-token; foo=bar")
    }

    @Test
    func `claude snapshot does not fall back to config cookie for malformed selected token account`() {
        let settings = Self.makeSettingsStore()
        settings.claudeCookieSource = .manual
        settings.claudeCookieHeader = "Cookie: sessionKey=sk-ant-config-cookie"
        settings.addTokenAccount(provider: .claude, label: "Malformed", token: "Cookie:")

        let snapshot = settings.claudeSettingsSnapshot(tokenOverride: nil)

        #expect(snapshot.cookieSource == .manual)
        #expect(snapshot.manualCookieHeader?.isEmpty == true)
    }

    @Test
    func `opencode go token accounts force manual cookie routing`() {
        let settings = Self.makeSettingsStore()
        settings.addTokenAccount(provider: .opencodego, label: "Go", token: "auth=go-cookie")

        let snapshot = settings.opencodegoSettingsSnapshot(tokenOverride: nil)

        #expect(settings.opencodegoCookieSource == .manual)
        #expect(snapshot.cookieSource == .manual)
        #expect(snapshot.manualCookieHeader == "auth=go-cookie")
    }

    @Test
    func `opencode go snapshot preserves nil workspace id when settings are unset`() {
        let settings = Self.makeSettingsStore()

        let snapshot = settings.opencodegoSettingsSnapshot(tokenOverride: nil)

        #expect(settings.opencodegoWorkspaceID.isEmpty)
        #expect(snapshot.workspaceID == nil)
    }

    @Test
    func `token cost usage source detection`() throws {
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
    func `ensure token loaders execute`() {
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
        settings.ensureOllamaCookieLoaded()
        settings.ensureCopilotAPITokenLoaded()
        settings.ensureTokenAccountsLoaded()

        #expect(settings.zaiAPIToken.isEmpty)
        #expect(settings.syntheticAPIToken.isEmpty)
    }

    @Test
    func `keychain disable forces manual cookie sources`() throws {
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

    @Test
    func `claude keychain prompt mode defaults to only on user action`() {
        let settings = Self.makeSettingsStore()
        #expect(settings.claudeOAuthKeychainPromptMode == .onlyOnUserAction)
    }

    @Test
    func `claude keychain prompt mode persists across store reload`() throws {
        let suite = "SettingsStoreCoverageTests-claude-keychain-prompt-mode"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let first = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        first.claudeOAuthKeychainPromptMode = .never
        #expect(
            defaults.string(forKey: "claudeOAuthKeychainPromptMode")
                == ClaudeOAuthKeychainPromptMode.never.rawValue)

        let second = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(second.claudeOAuthKeychainPromptMode == .never)
    }

    @Test
    func `claude keychain prompt mode invalid raw falls back to only on user action`() throws {
        let suite = "SettingsStoreCoverageTests-claude-keychain-prompt-mode-invalid"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set("invalid-mode", forKey: "claudeOAuthKeychainPromptMode")
        let configStore = testConfigStore(suiteName: suite)

        let settings = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(settings.claudeOAuthKeychainPromptMode == .onlyOnUserAction)
    }

    @Test
    func `claude keychain read strategy defaults to security CLI experimental`() {
        let settings = Self.makeSettingsStore()
        #expect(settings.claudeOAuthKeychainReadStrategy == .securityCLIExperimental)
    }

    @Test
    func `claude keychain read strategy persists across store reload`() throws {
        let suite = "SettingsStoreCoverageTests-claude-keychain-read-strategy"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let first = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        first.claudeOAuthKeychainReadStrategy = .securityCLIExperimental
        #expect(
            defaults.string(forKey: "claudeOAuthKeychainReadStrategy")
                == ClaudeOAuthKeychainReadStrategy.securityCLIExperimental.rawValue)

        let second = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(second.claudeOAuthKeychainReadStrategy == .securityCLIExperimental)
    }

    @Test
    func `claude keychain read strategy invalid raw falls back to security framework`() throws {
        let suite = "SettingsStoreCoverageTests-claude-keychain-read-strategy-invalid"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set("invalid-strategy", forKey: "claudeOAuthKeychainReadStrategy")
        let configStore = testConfigStore(suiteName: suite)

        let settings = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(settings.claudeOAuthKeychainReadStrategy == .securityFramework)
    }

    @Test
    func `claude prompt free credentials toggle maps to read strategy`() {
        let settings = Self.makeSettingsStore()
        #expect(settings.claudeOAuthPromptFreeCredentialsEnabled == true)

        settings.claudeOAuthPromptFreeCredentialsEnabled = false
        #expect(settings.claudeOAuthKeychainReadStrategy == .securityFramework)

        settings.claudeOAuthPromptFreeCredentialsEnabled = true
        #expect(settings.claudeOAuthKeychainReadStrategy == .securityCLIExperimental)
    }

    @Test
    func `upsert antigravity oauth account adds and updates active token account`() throws {
        let settings = Self.makeSettingsStore()
        let first = AntigravityOAuthCredentials(
            accessToken: "first-access",
            refreshToken: "first-refresh",
            expiryDate: Date(timeIntervalSince1970: 1_700_000_000),
            email: "user@example.com")
        let updated = AntigravityOAuthCredentials(
            accessToken: "updated-access",
            refreshToken: "first-refresh",
            expiryDate: Date(timeIntervalSince1970: 1_700_000_100),
            email: "user@example.com")

        settings.upsertAntigravityOAuthAccount(first)
        settings.upsertAntigravityOAuthAccount(updated)

        let accounts = settings.tokenAccounts(for: .antigravity)
        #expect(accounts.count == 1)
        let account = try #require(accounts.first)
        #expect(account.label == "user@example.com")
        #expect(account.externalIdentifier == "user@example.com")
        #expect(settings.selectedTokenAccount(for: .antigravity)?.id == account.id)

        let decoded = try #require(AntigravityOAuthCredentialsStore.credentials(fromTokenAccountValue: account.token))
        #expect(decoded.accessToken == "updated-access")
    }

    @Test
    func `upsert antigravity oauth account does not merge missing email accounts by fallback label`() {
        let settings = Self.makeSettingsStore()
        let first = AntigravityOAuthCredentials(
            accessToken: "first-access",
            refreshToken: "first-refresh",
            expiryDate: Date(timeIntervalSince1970: 1_700_000_000),
            email: nil)
        let second = AntigravityOAuthCredentials(
            accessToken: "second-access",
            refreshToken: "second-refresh",
            expiryDate: Date(timeIntervalSince1970: 1_700_000_100),
            email: nil)

        settings.upsertAntigravityOAuthAccount(first)
        settings.upsertAntigravityOAuthAccount(second)

        let accounts = settings.tokenAccounts(for: .antigravity)
        #expect(accounts.count == 2)
        #expect(accounts.map(\.label) == ["Google Account 1", "Google Account 2"])
        #expect(settings.selectedTokenAccount(for: .antigravity)?.id == accounts.last?.id)
    }

    @Test
    func `removing last antigravity oauth account clears matching shared credentials`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-shared-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sharedStore = AntigravityOAuthCredentialsStore(
            fileURL: root.appendingPathComponent("oauth_creds.json"))
        let credentials = AntigravityOAuthCredentials(
            accessToken: "shared-access",
            refreshToken: "shared-refresh",
            expiryDate: Date(timeIntervalSince1970: 1_700_000_000),
            email: "user@example.com")
        try sharedStore.save(credentials)
        let settings = Self.makeSettingsStore(
            suiteName: "SettingsStoreCoverageTests-antigravity-remove-shared",
            antigravityOAuthCredentialsStore: sharedStore)

        settings.upsertAntigravityOAuthAccount(credentials)
        let account = try #require(settings.selectedTokenAccount(for: .antigravity))
        settings.removeTokenAccount(provider: .antigravity, accountID: account.id)

        #expect(settings.tokenAccounts(for: .antigravity).isEmpty)
        #expect(try sharedStore.load() == nil)
    }

    @Test
    func `removing antigravity oauth account preserves freshly reauthenticated credentials`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-shared-reauth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sharedStore = AntigravityOAuthCredentialsStore(
            fileURL: root.appendingPathComponent("oauth_creds.json"))
        let removed = AntigravityOAuthCredentials(
            accessToken: "removed-access",
            refreshToken: "removed-refresh",
            expiryDate: Date(timeIntervalSince1970: 1_700_000_000),
            email: "user@example.com")
        let refreshed = AntigravityOAuthCredentials(
            accessToken: "fresh-access",
            refreshToken: "fresh-refresh",
            expiryDate: Date(timeIntervalSince1970: 1_700_000_100),
            email: "user@example.com")
        try sharedStore.save(refreshed)
        let settings = Self.makeSettingsStore(
            suiteName: "SettingsStoreCoverageTests-antigravity-preserve-reauth",
            antigravityOAuthCredentialsStore: sharedStore)

        settings.upsertAntigravityOAuthAccount(removed)
        let account = try #require(settings.selectedTokenAccount(for: .antigravity))
        settings.removeTokenAccount(provider: .antigravity, accountID: account.id)

        #expect(try sharedStore.load() == refreshed)
    }

    @Test
    func `removing antigravity oauth account preserves different shared credentials`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-shared-preserve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sharedStore = AntigravityOAuthCredentialsStore(
            fileURL: root.appendingPathComponent("oauth_creds.json"))
        let removed = AntigravityOAuthCredentials(
            accessToken: "removed-access",
            refreshToken: "removed-refresh",
            expiryDate: Date(timeIntervalSince1970: 1_700_000_000),
            email: "removed@example.com")
        let shared = AntigravityOAuthCredentials(
            accessToken: "shared-access",
            refreshToken: "shared-refresh",
            expiryDate: Date(timeIntervalSince1970: 1_700_000_000),
            email: "shared@example.com")
        try sharedStore.save(shared)
        let settings = Self.makeSettingsStore(
            suiteName: "SettingsStoreCoverageTests-antigravity-preserve-shared",
            antigravityOAuthCredentialsStore: sharedStore)

        settings.upsertAntigravityOAuthAccount(removed)
        let account = try #require(settings.selectedTokenAccount(for: .antigravity))
        settings.removeTokenAccount(provider: .antigravity, accountID: account.id)

        #expect(settings.tokenAccounts(for: .antigravity).isEmpty)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(try sharedStore.load() == shared)
    }

    @Test
    func `weekly progress work days defaults to nil and persists across store reload`() throws {
        let suite = "SettingsStoreCoverageTests-weekly-progress-work-days"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let fresh = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(fresh.weeklyProgressWorkDays == nil)

        fresh.weeklyProgressWorkDays = 5
        #expect(defaults.object(forKey: "weeklyProgressWorkDays") as? Int == 5)

        let reloaded = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(reloaded.weeklyProgressWorkDays == 5)

        fresh.weeklyProgressWorkDays = 4
        #expect(reloaded.weeklyProgressWorkDays == 5)

        let reloaded2 = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(reloaded2.weeklyProgressWorkDays == 4)

        reloaded2.weeklyProgressWorkDays = 7
        let reloaded3 = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(reloaded3.weeklyProgressWorkDays == 7)

        reloaded3.weeklyProgressWorkDays = nil
        #expect(defaults.object(forKey: "weeklyProgressWorkDays") == nil)
        let reloaded4 = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        #expect(reloaded4.weeklyProgressWorkDays == nil)
    }

    private static func makeSettingsStore(
        suiteName: String = "SettingsStoreCoverageTests",
        antigravityOAuthCredentialsStore: AntigravityOAuthCredentialsStore = AntigravityOAuthCredentialsStore())
        -> SettingsStore
    {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "debugDisableKeychainAccess")
        let configStore = testConfigStore(suiteName: suiteName)
        return Self.makeSettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            antigravityOAuthCredentialsStore: antigravityOAuthCredentialsStore)
    }

    private static func makeSettingsStore(
        userDefaults: UserDefaults,
        configStore: CodexBarConfigStore,
        antigravityOAuthCredentialsStore: AntigravityOAuthCredentialsStore = AntigravityOAuthCredentialsStore())
        -> SettingsStore
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
            tokenAccountStore: InMemoryTokenAccountStore(),
            antigravityOAuthCredentialsStore: antigravityOAuthCredentialsStore)
    }

    private static func waitForSharedAntigravityCredentials(
        in store: AntigravityOAuthCredentialsStore,
        matches predicate: (AntigravityOAuthCredentials?) -> Bool) async throws
        -> AntigravityOAuthCredentials?
    {
        for _ in 0..<100 {
            let credentials = try store.load()
            if predicate(credentials) {
                return credentials
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try store.load()
    }
}
