import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeProfileConfigDirTests {
    @MainActor
    private static func makeSettings(suite: String) throws -> SettingsStore {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "providerDetectionCompleted")
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.providerDetectionCompleted = true
        return settings
    }

    @Test
    func `legacy config without claude profile keys decodes to nil`() throws {
        let legacyJSON = """
        {
            "version": 1,
            "providers": [
                {
                    "id": "claude"
                }
            ]
        }
        """

        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: Data(legacyJSON.utf8))

        #expect(decoded.providerConfig(for: .claude)?.claudeActiveSource == nil)
        #expect(decoded.providerConfig(for: .claude)?.claudeProfileConfigDirs == nil)
    }

    @Test
    func `provider config round trips profile config dirs and active source`() throws {
        var provider = ProviderConfig(id: .claude)
        provider.claudeProfileConfigDirs = ["~/.claude-work", "/tmp/claude-personal"]
        provider.claudeActiveSource = .profileConfigDir(path: "~/.claude-work")
        let config = CodexBarConfig(providers: [provider])

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: data)

        #expect(decoded.providerConfig(for: .claude)?.claudeProfileConfigDirs ==
            ["~/.claude-work", "/tmp/claude-personal"])
        #expect(decoded.providerConfig(for: .claude)?.claudeActiveSource ==
            .profileConfigDir(path: "~/.claude-work"))
    }

    @Test
    func `active source with blank path decodes to ambient`() throws {
        let json = """
        {
            "version": 1,
            "providers": [
                {
                    "id": "claude",
                    "claudeActiveSource": { "kind": "profileConfigDir", "configDirPath": "  " }
                }
            ]
        }
        """

        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: Data(json.utf8))

        #expect(decoded.providerConfig(for: .claude)?.claudeActiveSource == .ambient)
    }

    @Test
    func `unknown active source kind fails soft`() throws {
        let json = """
        {
            "version": 1,
            "providers": [
                {
                    "id": "claude",
                    "claudeActiveSource": { "kind": "futureKind" }
                }
            ]
        }
        """

        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: Data(json.utf8))

        #expect(decoded.providerConfig(for: .claude)?.claudeActiveSource == nil)
    }

    @Test
    func `config dir normalization expands tilde and rejects relative paths`() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        #expect(ClaudeConfigDirScope.normalizedConfigDirPath("~/.claude-work") == "\(home)/.claude-work")
        #expect(ClaudeConfigDirScope.normalizedConfigDirPath("~") == home)
        #expect(ClaudeConfigDirScope.normalizedConfigDirPath("/tmp/claude//") == "/tmp/claude")
        #expect(ClaudeConfigDirScope.normalizedConfigDirPath("relative/path") == nil)
        #expect(ClaudeConfigDirScope.normalizedConfigDirPath("~user/claude") == nil)
        #expect(ClaudeConfigDirScope.normalizedConfigDirPath("   ") == nil)
        #expect(ClaudeConfigDirScope.normalizedConfigDirPath(nil) == nil)
    }

    @Test
    func `scoped environment sets config dir and drops secure storage override`() {
        let base = [
            "HOME": "/Users/example",
            ClaudeConfigPaths.configDirectoryEnvironmentKey: "/Users/example/.claude",
            ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey: "/Users/example/.claude-secure",
        ]

        let scoped = ClaudeConfigDirScope.scopedEnvironment(base: base, configDir: "/tmp/claude-work")

        #expect(scoped[ClaudeConfigPaths.configDirectoryEnvironmentKey] == "/tmp/claude-work")
        #expect(scoped[ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey] == nil)
        #expect(scoped["HOME"] == "/Users/example")
        #expect(ClaudeConfigDirScope.scopedEnvironment(base: base, configDir: nil) == base)
    }

    @Test
    func `scoped environment strips provider-wide credential authorities`() {
        let base = [
            "HOME": "/Users/example",
            ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey: "sk-ant-admin-test",
            ClaudeAdminAPISettingsReader.alternateAdminAPIKeyEnvironmentKey: "sk-ant-admin-alt",
            ClaudeOAuthCredentialsStore.environmentTokenKey: "sk-ant-oat-ambient",
            ClaudeOAuthCredentialsStore.environmentScopesKey: "user:profile",
        ]

        let scoped = ClaudeConfigDirScope.scopedEnvironment(base: base, configDir: "/tmp/claude-work")

        #expect(scoped[ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey] == nil)
        #expect(scoped[ClaudeAdminAPISettingsReader.alternateAdminAPIKeyEnvironmentKey] == nil)
        #expect(scoped[ClaudeOAuthCredentialsStore.environmentTokenKey] == nil)
        #expect(scoped[ClaudeOAuthCredentialsStore.environmentScopesKey] == nil)
    }

    @Test
    @MainActor
    func `selected profile restricts snapshot to profile-scoped credential paths`() throws {
        let suite = "ClaudeProfileConfigDirTests-snapshot-authority"
        let settings = try Self.makeSettings(suite: suite)
        settings.claudeAdminAPIKey = "sk-ant-admin-test"
        settings.claudeCookieHeader = "sessionKey=sk-ant-ambient"
        settings.claudeCookieSource = .manual
        settings.claudeUsageDataSource = .web
        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = ["/tmp/claude-work"]
        }

        settings.claudeActiveSource = .profileConfigDir(path: "/tmp/claude-work")
        let scoped = settings.claudeSettingsSnapshot(tokenOverride: nil)
        #expect(scoped.cookieSource == .off)
        #expect(scoped.manualCookieHeader?.isEmpty != false)
        #expect(scoped.usageDataSource == .auto)
        #expect(scoped.webExtrasEnabled == false)

        settings.claudeActiveSource = .ambient
        let ambient = settings.claudeSettingsSnapshot(tokenOverride: nil)
        #expect(ambient.cookieSource == .manual)
        #expect(ambient.manualCookieHeader == "sessionKey=sk-ant-ambient")
    }

    @Test
    func `claude keychain service targets the profile-suffixed item for custom config dirs`() {
        let base = ["HOME": "/Users/example"]

        #expect(ClaudeOAuthCredentialsStore.claudeKeychainService(environment: base) ==
            "Claude Code-credentials")
        // Claude Code stores an explicitly configured default root in the bare item too.
        #expect(ClaudeOAuthCredentialsStore.claudeKeychainService(
            environment: base.merging(
                [ClaudeConfigPaths.configDirectoryEnvironmentKey: "/Users/example/.claude"],
                uniquingKeysWith: { _, new in new })) ==
            "Claude Code-credentials")
        // Suffix is the first 8 hex chars of SHA-256 of the absolute config dir path.
        #expect(ClaudeOAuthCredentialsStore.claudeKeychainService(
            environment: base.merging(
                [ClaudeConfigPaths.configDirectoryEnvironmentKey: "/tmp/claude-work"],
                uniquingKeysWith: { _, new in new })) ==
            "Claude Code-credentials-bfc1769a")
    }

    @Test
    func `claude cost cache scope key partitions custom config dirs only`() {
        let base = ["HOME": "/Users/example"]

        #expect(CostUsageScanner.claudeCacheScopeKey(environment: base) == nil)
        // An explicitly configured default root stays in the legacy unsuffixed cache.
        #expect(CostUsageScanner.claudeCacheScopeKey(
            environment: base.merging(
                [ClaudeConfigPaths.configDirectoryEnvironmentKey: "/Users/example/.claude"],
                uniquingKeysWith: { _, new in new })) == nil)
        // Same suffix convention as the profile Keychain item: first 8 hex chars of SHA-256 of the root.
        #expect(CostUsageScanner.claudeCacheScopeKey(
            environment: base.merging(
                [ClaudeConfigPaths.configDirectoryEnvironmentKey: "/tmp/claude-work"],
                uniquingKeysWith: { _, new in new })) == "bfc1769a")
    }

    @Test
    func `claude cost cache file is partitioned by scope key`() {
        let root = URL(fileURLWithPath: "/tmp/codexbar-cache-test", isDirectory: true)

        #expect(CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: root).lastPathComponent ==
            "claude-v6.json")
        #expect(CostUsageClaudeCacheIO.cacheFileURL(
            provider: .claude,
            cacheRoot: root,
            scopeKey: "bfc1769a").lastPathComponent ==
            "claude-v6-bfc1769a.json")
    }

    @Test
    @MainActor
    func `settings store normalizes and deduplicates profile config dirs`() throws {
        let suite = "ClaudeProfileConfigDirTests-normalization"
        let settings = try Self.makeSettings(suite: suite)
        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = [
                "/tmp/claude-work",
                "/tmp/claude-work/",
                "relative/ignored",
                "~/.claude-personal",
            ]
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(settings.claudeProfileConfigDirs == ["/tmp/claude-work", "\(home)/.claude-personal"])
    }

    @Test
    @MainActor
    func `resolved active source falls back to ambient when dir leaves the allow-list`() throws {
        let suite = "ClaudeProfileConfigDirTests-fallback"
        let settings = try Self.makeSettings(suite: suite)
        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = ["/tmp/claude-work"]
            entry.claudeActiveSource = .profileConfigDir(path: "/tmp/claude-work")
        }

        #expect(settings.claudeResolvedActiveSource == .profileConfigDir(path: "/tmp/claude-work"))

        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = []
        }

        #expect(settings.claudeResolvedActiveSource == .ambient)
        #expect(settings.profileClaudeConfigDir(
            forActiveSource: .profileConfigDir(path: "/tmp/claude-work")) == nil)
    }

    @Test
    @MainActor
    func `adding profile config dirs normalizes stores and rejects duplicates`() throws {
        let suite = "ClaudeProfileConfigDirTests-add"
        let settings = try Self.makeSettings(suite: suite)
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        #expect(settings.addClaudeProfileConfigDir("\(home)/.claude-work") == true)
        #expect(settings.addClaudeProfileConfigDir("~/.claude-work") == false)
        #expect(settings.addClaudeProfileConfigDir("relative/rejected") == false)
        #expect(settings.addClaudeProfileConfigDir("/tmp/claude-other") == true)

        #expect(settings.claudeProfileConfigDirs == ["\(home)/.claude-work", "/tmp/claude-other"])
        // Home-relative entries stay portable in config.json.
        #expect(settings.configSnapshot.providerConfig(for: .claude)?.claudeProfileConfigDirs ==
            ["~/.claude-work", "/tmp/claude-other"])
    }

    @Test
    @MainActor
    func `removing the selected profile config dir falls back to ambient`() throws {
        let suite = "ClaudeProfileConfigDirTests-remove"
        let settings = try Self.makeSettings(suite: suite)
        settings.addClaudeProfileConfigDir("/tmp/claude-work")
        settings.addClaudeProfileConfigDir("/tmp/claude-other")
        settings.claudeActiveSource = .profileConfigDir(path: "/tmp/claude-work")

        settings.removeClaudeProfileConfigDir("/tmp/claude-work")

        #expect(settings.claudeProfileConfigDirs == ["/tmp/claude-other"])
        #expect(settings.claudeActiveSource == .ambient)
        #expect(settings.claudeResolvedActiveSource == .ambient)

        settings.removeClaudeProfileConfigDir("/tmp/claude-other")
        #expect(settings.claudeProfileConfigDirs.isEmpty)
        #expect(settings.configSnapshot.providerConfig(for: .claude)?.claudeProfileConfigDirs == nil)
    }

    @Test
    @MainActor
    func `removing an unselected profile config dir keeps the selection`() throws {
        let suite = "ClaudeProfileConfigDirTests-remove-unselected"
        let settings = try Self.makeSettings(suite: suite)
        settings.addClaudeProfileConfigDir("/tmp/claude-work")
        settings.addClaudeProfileConfigDir("/tmp/claude-other")
        settings.claudeActiveSource = .profileConfigDir(path: "/tmp/claude-work")

        settings.removeClaudeProfileConfigDir("/tmp/claude-other")

        #expect(settings.claudeProfileConfigDirs == ["/tmp/claude-work"])
        #expect(settings.claudeResolvedActiveSource == .profileConfigDir(path: "/tmp/claude-work"))
    }

    @MainActor
    private static func claudeMenuSubmenus(
        settings: SettingsStore,
        environmentBase: [String: String] = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path])
        -> [(String, [MenuDescriptor.SubmenuItem])]
    {
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: environmentBase)
        return MenuDescriptor.build(
            provider: .claude,
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updateReady: false)
            .sections
            .flatMap(\.entries)
            .compactMap { entry in
                guard case let .submenu(title, _, items) = entry else { return nil }
                return (title, items)
            }
    }

    @Test
    @MainActor
    func `claude menu offers account directory submenu with active checkmark`() throws {
        let suite = "ClaudeProfileConfigDirTests-menu"
        let settings = try Self.makeSettings(suite: suite)
        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = ["/tmp/claude-work", "/tmp/claude-other"]
            entry.claudeActiveSource = .profileConfigDir(path: "/tmp/claude-work")
        }

        let submenu = try #require(Self.claudeMenuSubmenus(settings: settings)
            .first(where: { $0.0 == "Account Directory" }))

        #expect(submenu.1.map(\.title) == ["Default (~/.claude)", "/tmp/claude-work", "/tmp/claude-other"])
        #expect(submenu.1.map(\.isChecked) == [false, true, false])
        #expect(submenu.1.map(\.isEnabled) == [true, false, true])
        #expect(submenu.1.map(\.action) == [
            .selectClaudeProfileDir(path: nil),
            .selectClaudeProfileDir(path: "/tmp/claude-work"),
            .selectClaudeProfileDir(path: "/tmp/claude-other"),
        ])
    }

    @Test
    @MainActor
    func `default entry labels an ambient config dir from the environment`() throws {
        let suite = "ClaudeProfileConfigDirTests-menu-ambient-label"
        let settings = try Self.makeSettings(suite: suite)
        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = ["/tmp/claude-work"]
        }

        let submenu = try #require(Self.claudeMenuSubmenus(
            settings: settings,
            environmentBase: [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ClaudeConfigPaths.configDirectoryEnvironmentKey: "/tmp/claude-ambient",
            ])
            .first(where: { $0.0 == "Account Directory" }))

        #expect(submenu.1.first?.title == "Default (/tmp/claude-ambient, from environment)")
    }

    @Test
    @MainActor
    func `selected profile directory suppresses saved claude token accounts`() throws {
        let suite = "ClaudeProfileConfigDirTests-token-authority"
        let settings = try Self.makeSettings(suite: suite)
        settings.claudeCookieSource = .manual
        settings.addTokenAccount(provider: .claude, label: "Saved", token: "sk-ant-session-token")
        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = ["/tmp/claude-work"]
        }

        #expect(settings.effectiveSelectedTokenAccount(for: .claude) != nil)

        settings.claudeActiveSource = .profileConfigDir(path: "/tmp/claude-work")
        #expect(settings.effectiveSelectedTokenAccount(for: .claude) == nil)
        #expect(ProviderTokenAccountSelection.selectedAccount(
            provider: .claude,
            settings: settings,
            override: nil) == nil)

        settings.claudeActiveSource = .ambient
        #expect(settings.effectiveSelectedTokenAccount(for: .claude) != nil)
    }

    @Test
    func `cost scan roots follow the fetch environment even for the default directory`() {
        let base = ["HOME": "/Users/example"]

        var defaultOptions = CostUsageScanner.Options()
        let defaultKey = CostUsageFetcher.applyClaudeProfileScope(
            to: &defaultOptions,
            provider: .claude,
            environment: base.merging(
                [ClaudeConfigPaths.configDirectoryEnvironmentKey: "/Users/example/.claude"],
                uniquingKeysWith: { _, new in new }))
        #expect(defaultKey == nil)
        #expect(defaultOptions.claudeProjectsRoots?.map(\.path)
            .contains("/Users/example/.claude/projects") == true)

        var scopedOptions = CostUsageScanner.Options()
        let scopedKey = CostUsageFetcher.applyClaudeProfileScope(
            to: &scopedOptions,
            provider: .claude,
            environment: base.merging(
                [ClaudeConfigPaths.configDirectoryEnvironmentKey: "/tmp/claude-work"],
                uniquingKeysWith: { _, new in new }))
        #expect(scopedKey == "bfc1769a")
        #expect(scopedOptions.claudeProjectsRoots?.map(\.path) == ["/tmp/claude-work/projects"])
        #expect(scopedOptions.claudeCacheScopeKey == "bfc1769a")

        var otherOptions = CostUsageScanner.Options()
        let otherKey = CostUsageFetcher.applyClaudeProfileScope(
            to: &otherOptions,
            provider: .codex,
            environment: base)
        #expect(otherKey == nil)
        #expect(otherOptions.claudeProjectsRoots == nil)
    }

    @Test
    func `selected claude profile excludes ambient pi sessions from local cost`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-08T10-00-00-000Z_claude.jsonl",
            contents: env.jsonl([[
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "anthropic",
                    "model": "claude-sonnet-4-5",
                    "usage": ["input": 50, "output": 5, "totalTokens": 55],
                ],
            ]]))
        let profileRoot = env.root.appendingPathComponent("claude-profile", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profileRoot.appendingPathComponent("projects", isDirectory: true),
            withIntermediateDirectories: true)

        var options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)

        let ambient = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            environment: ["HOME": env.root.path],
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: true,
            scannerOptions: options,
            piScannerOptions: piOptions)
        let scoped = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            environment: [
                "HOME": env.root.path,
                ClaudeConfigPaths.configDirectoryEnvironmentKey: profileRoot.path,
            ],
            now: day.addingTimeInterval(1),
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: true,
            scannerOptions: options,
            piScannerOptions: piOptions)

        let explicitDefault = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            environment: [
                "HOME": env.root.path,
                ClaudeConfigPaths.configDirectoryEnvironmentKey: env.root.path + "/.claude",
            ],
            now: day.addingTimeInterval(2),
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: true,
            scannerOptions: options,
            piScannerOptions: piOptions)

        // Only the truly unscoped default fetch merges home-level pi sessions; any selected config
        // directory — including an explicitly selected default — excludes them.
        #expect(ambient.sessionTokens == 55)
        #expect(scoped.sessionTokens == 0)
        #expect(explicitDefault.sessionTokens == 0)
    }

    @Test
    @MainActor
    func `selected profile restricts persisted api and web sources to profile paths`() throws {
        let suite = "ClaudeProfileConfigDirTests-source-routing"
        let settings = try Self.makeSettings(suite: suite)
        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = ["/tmp/claude-work"]
        }

        for persisted in [ClaudeUsageDataSource.api, .web] {
            settings.claudeUsageDataSource = persisted
            settings.claudeActiveSource = .profileConfigDir(path: "/tmp/claude-work")
            #expect(settings.claudeEffectiveUsageDataSource == .auto)
            #expect(ProviderRegistry.resolvedSourceMode(
                provider: .claude,
                settings: settings,
                account: nil) == .auto)

            settings.claudeActiveSource = .ambient
            #expect(settings.claudeEffectiveUsageDataSource == persisted)
        }

        settings.claudeUsageDataSource = .cli
        settings.claudeActiveSource = .profileConfigDir(path: "/tmp/claude-work")
        #expect(settings.claudeEffectiveUsageDataSource == .cli)
    }

    @Test
    @MainActor
    func `usage source picker explains the profile restriction for api and web choices`() throws {
        let suite = "ClaudeProfileConfigDirTests-picker-honesty"
        let settings = try Self.makeSettings(suite: suite)
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: ["HOME": FileManager.default.homeDirectoryForCurrentUser.path])
        settings.claudeUsageDataSource = .api
        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = ["/tmp/claude-work"]
        }
        let pane = ProvidersPane(settings: settings, store: store)

        settings.claudeActiveSource = .profileConfigDir(path: "/tmp/claude-work")
        let restricted = pane._test_settingsPickers(for: .claude)
            .first { $0.id == "claude-usage-source" }
        #expect(restricted?.dynamicSubtitle?()?.contains("runs as Auto") == true)

        settings.claudeActiveSource = .ambient
        let ambient = pane._test_settingsPickers(for: .claude)
            .first { $0.id == "claude-usage-source" }
        #expect(ambient?.dynamicSubtitle?() == nil)
    }

    @Test
    @MainActor
    func `claude-swap presentation hides the account directory submenu`() throws {
        let suite = "ClaudeProfileConfigDirTests-swap-precedence"
        let settings = try Self.makeSettings(suite: suite)
        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = ["/tmp/claude-work"]
        }
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: ["HOME": FileManager.default.homeDirectoryForCurrentUser.path])
        let now = Date(timeIntervalSince1970: 1_782_000_000)
        store.claudeSwapAccountSnapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: (1...2).map { number in
                    ClaudeSwapAccountRow(
                        number: number,
                        email: "account\(number)@example.com",
                        isActive: number == 1,
                        usageStatus: .ok,
                        fiveHour: ClaudeSwapUsageWindow(
                            usedPercent: 20,
                            resetsAt: now.addingTimeInterval(3600)),
                        sevenDay: nil,
                        scoped: [])
                }),
            now: now)

        let hasSubmenu = MenuDescriptor.build(
            provider: .claude,
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updateReady: false)
            .sections
            .flatMap(\.entries)
            .contains { entry in
                guard case let .submenu(title, _, _) = entry else { return false }
                return title == "Account Directory"
            }

        #expect(hasSubmenu == false)
    }

    @Test
    @MainActor
    func `claude menu hides account directory submenu without configured dirs`() throws {
        let suite = "ClaudeProfileConfigDirTests-menu-hidden"
        let settings = try Self.makeSettings(suite: suite)

        let hasSubmenu = Self.claudeMenuSubmenus(settings: settings)
            .contains { $0.0 == "Account Directory" }

        #expect(hasSubmenu == false)
    }

    @Test
    @MainActor
    func `provider registry scopes selected claude profile config dir`() throws {
        let suite = "ClaudeProfileConfigDirTests-routing"
        let settings = try Self.makeSettings(suite: suite)
        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = ["/tmp/claude-work"]
            entry.claudeActiveSource = .profileConfigDir(path: "/tmp/claude-work")
        }

        let environment = ProviderRegistry.makeEnvironment(
            base: [
                ClaudeConfigPaths.configDirectoryEnvironmentKey: "/tmp/ambient-claude",
                ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey: "/tmp/ambient-secure",
            ],
            provider: .claude,
            settings: settings,
            tokenOverride: nil)

        #expect(environment[ClaudeConfigPaths.configDirectoryEnvironmentKey] == "/tmp/claude-work")
        #expect(environment[ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey] == nil)
    }

    @Test
    @MainActor
    func `provider registry leaves ambient claude environment untouched without a selection`() throws {
        let suite = "ClaudeProfileConfigDirTests-ambient"
        let settings = try Self.makeSettings(suite: suite)
        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = ["/tmp/claude-work"]
        }

        let environment = ProviderRegistry.makeEnvironment(
            base: [ClaudeConfigPaths.configDirectoryEnvironmentKey: "/tmp/ambient-claude"],
            provider: .claude,
            settings: settings,
            tokenOverride: nil)

        #expect(environment[ClaudeConfigPaths.configDirectoryEnvironmentKey] == "/tmp/ambient-claude")
    }
}
