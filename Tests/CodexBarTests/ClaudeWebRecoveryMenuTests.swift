import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct ClaudeWebRecoveryMenuTests {
    private static let cloudflareChallengeMessage =
        "claude.ai is behind a Cloudflare challenge, often caused by VPN or datacenter networks. " +
        "Re-authenticating will not help. Switch Claude Usage source to OAuth in Settings " +
        "(Usage credits balance will be unavailable), or try a different network."

    @Test
    func `unauthorized error explains how to restore web usage`() {
        #expect(
            ClaudeWebAPIFetcher.FetchError.unauthorized.localizedDescription ==
                "Sign in to claude.ai (or refresh Claude cookies) to load usage data.")
    }

    private func makeSettings(root: URL) -> SettingsStore {
        SettingsStore(
            userDefaults: InMemoryUserDefaults(),
            configStore: CodexBarConfigStore(fileURL: root.appendingPathComponent("config.json")),
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
            tokenAccountStore: InMemoryTokenAccountStore(fileURL: root.appendingPathComponent("accounts.json")),
            antigravityOAuthCredentialsStore: AntigravityOAuthCredentialsStore(
                fileURL: root.appendingPathComponent("antigravity.json")),
            keychainAccessPolicy: SettingsStoreKeychainAccessPolicy(
                setDisabled: { _ in }, isExplicitlyDisabled: { false }),
            performInitialProviderDetection: false)
    }

    private static func claudeSwapAccounts(count: Int) -> [ProviderAccountUsageSnapshot] {
        guard count > 0 else { return [] }
        let now = Date(timeIntervalSince1970: 1_782_000_000)
        return ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: (1...count).map { number in
                    ClaudeSwapAccountRow(
                        number: number,
                        email: "account\(number)@example.com",
                        isActive: number == 1,
                        usageStatus: .ok,
                        fiveHour: ClaudeSwapUsageWindow(
                            usedPercent: Double(20 + number),
                            resetsAt: now.addingTimeInterval(3600)),
                        sevenDay: nil,
                        scoped: [])
                }),
            now: now)
    }

    private func actions(
        error: String? = nil,
        source: ClaudeUsageDataSource,
        cookieSource: ProviderCookieSource = .auto,
        selectedSessionKey: Bool = false,
        authenticatedAccountEmail: String? = nil,
        authenticatedOAuthWithoutEmail: Bool = false,
        snapshot: UsageSnapshot? = nil,
        rawSourceLabel: String? = nil,
        claudeSwapAccountCount: Int = 0,
        showSingleSwapAccount: Bool = false,
        attempts: [ProviderFetchAttempt] = []) -> [(String, MenuDescriptor.MenuAction)]
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeWebRecoveryMenuTests-\(UUID().uuidString)", isDirectory: true)
        let settings = self.makeSettings(root: root)
        defer {
            settings.configFileWatcher?.stop()
            try? FileManager.default.removeItem(at: root)
        }
        settings.claudeUsageDataSource = source
        settings.claudeSwapShowSingleAccount = showSingleSwapAccount
        if selectedSessionKey {
            settings.addTokenAccount(provider: .claude, label: "Session", token: "sk-ant-session-token")
        }
        settings.claudeCookieSource = cookieSource
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store.claudeSwapAccountSnapshots = Self.claudeSwapAccounts(count: claudeSwapAccountCount)
        if let snapshot {
            store._setSnapshotForTesting(snapshot, provider: .claude)
        } else if authenticatedAccountEmail != nil || authenticatedOAuthWithoutEmail {
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: authenticatedOAuthWithoutEmail
                        ? RateWindow(
                            usedPercent: 25,
                            windowMinutes: 5 * 60,
                            resetsAt: nil,
                            resetDescription: nil)
                        : nil,
                    secondary: nil,
                    updatedAt: Date(),
                    identity: ProviderIdentitySnapshot(
                        providerID: .claude,
                        accountEmail: authenticatedAccountEmail,
                        accountOrganization: nil,
                        loginMethod: "Claude Pro")),
                provider: .claude)
        }
        store.errors[.claude] = error
        store.lastSourceLabels[.claude] = rawSourceLabel
        store.lastFetchAttempts[.claude] = attempts

        return MenuDescriptor.build(
            provider: .claude,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false)
            .sections
            .flatMap(\.entries)
            .compactMap { entry in
                guard case let .action(label, action) = entry else { return nil }
                return (label, action)
            }
    }

    private static func identitylessCLIUsage(hasRateLimits: Bool = true) -> UsageSnapshot {
        UsageSnapshot(
            primary: hasRateLimits
                ? RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
                : nil,
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_782_000_000),
            dataConfidence: .percentOnly)
    }

    private static let successfulCLI = ProviderFetchAttempt(
        strategyID: "claude.cli", kind: .cli, wasAvailable: true, errorDescription: nil)

    @Test(arguments: [ClaudeUsageDataSource.auto, .cli])
    func `successful identity-less CLI usage offers switch account`(source: ClaudeUsageDataSource) {
        let actions = self.actions(
            source: source,
            snapshot: Self.identitylessCLIUsage(),
            rawSourceLabel: "claude",
            attempts: [
                ProviderFetchAttempt(
                    strategyID: "claude.oauth",
                    kind: .oauth,
                    wasAvailable: true,
                    errorDescription: "OAuth credentials not found"),
                Self.successfulCLI,
            ])

        #expect(actions.contains { $0.0 == "Switch Account..." && $0.1 == .switchAccount(.claude) })
        #expect(!actions.contains { $0.0 == "Sign in with Claude Code..." || $0.0 == "Add Account..." })
    }

    @Test(arguments: [nil, "history", "oauth", "cli"] as [String?])
    func `CLI attempts without a published CLI source do not authenticate history`(sourceLabel: String?) {
        let actions = self.actions(
            source: .auto,
            snapshot: Self.identitylessCLIUsage(),
            rawSourceLabel: sourceLabel,
            attempts: [Self.successfulCLI])

        #expect(actions.contains { $0.0 == "Sign in with Claude Code..." })
    }

    @Test
    func `retained CLI usage after failed unavailable or absent attempts still offers sign in`() {
        let attempts: [[ProviderFetchAttempt]] = [
            [],
            [.init(strategyID: "claude.cli", kind: .cli, wasAvailable: false, errorDescription: nil)],
            [.init(strategyID: "claude.cli", kind: .cli, wasAvailable: true, errorDescription: "Timed out")],
            [
                Self.successfulCLI,
                .init(strategyID: "claude.web", kind: .web, wasAvailable: true, errorDescription: nil),
            ],
        ]
        for attempt in attempts {
            let actions = self.actions(
                source: .auto, snapshot: Self.identitylessCLIUsage(), rawSourceLabel: "claude", attempts: attempt)

            #expect(actions.contains { $0.0 == "Sign in with Claude Code..." })
            #expect(!actions.contains { $0.0 == "Switch Account..." })
        }
    }

    @Test
    func `CLI success without a quota snapshot does not authenticate an account`() {
        for snapshot in [nil, Self.identitylessCLIUsage(hasRateLimits: false)] {
            let actions = self.actions(
                source: .cli, snapshot: snapshot, rawSourceLabel: "claude", attempts: [Self.successfulCLI])

            #expect(actions.contains { $0.0 == "Sign in with Claude Code..." })
        }
    }

    @Test
    func `current recovery errors retain priority over an earlier CLI success`() {
        let actions = self.actions(
            error: ClaudeOAuthUnreadableCredentialsError.descriptionPrefix,
            source: .auto,
            snapshot: Self.identitylessCLIUsage(),
            rawSourceLabel: "claude",
            attempts: [Self.successfulCLI])

        #expect(actions.contains {
            $0.0 == "Allow reading Claude Code's credentials in Settings…" &&
                $0.1 == .providerSettings(.claude)
        })
        #expect(!actions.contains { $0.0 == "Switch Account..." })
    }

    @Test(arguments: [1, 2])
    func `swap account presentation keeps ambient sign in after CLI success`(count: Int) {
        let actions = self.actions(
            source: .auto,
            snapshot: Self.identitylessCLIUsage(),
            rawSourceLabel: "claude",
            claudeSwapAccountCount: count,
            showSingleSwapAccount: true,
            attempts: [Self.successfulCLI])

        #expect(actions.contains { $0.0 == "Sign in with Claude Code..." && $0.1 == .switchAccount(.claude) })
        #expect(!actions.contains { $0.0 == "Switch Account..." })
    }

    @Test
    func `default account action localizes ambient Claude Code sign in`() {
        let actions = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hant") {
            self.actions(source: .auto)
        }

        #expect(actions.contains {
            $0.0 == "使用 Claude Code 登入…" && $0.1 == .switchAccount(.claude)
        })
        #expect(!actions.contains { $0.0 == "Add Account..." })
    }

    @Test
    func `authenticated Claude account shows switch action instead of sign in`() {
        let actions = self.actions(
            source: .auto,
            authenticatedAccountEmail: "claude@example.com")

        #expect(actions.contains {
            $0.0 == "Switch Account..." && $0.1 == .switchAccount(.claude)
        })
        #expect(!actions.contains { $0.0 == "Sign in with Claude Code..." })
    }

    @Test
    func `swap account presentation disambiguates ambient Claude Code sign in`() {
        let actions = self.actions(
            source: .auto,
            authenticatedAccountEmail: "claude@example.com",
            claudeSwapAccountCount: 2)

        #expect(actions.contains {
            $0.0 == "Sign in with Claude Code..." && $0.1 == .switchAccount(.claude)
        })
        #expect(!actions.contains { $0.0 == "Switch Account..." })
        #expect(!actions.contains { $0.0 == "Add Account..." })
    }

    @Test
    func `email-less Claude OAuth snapshot shows switch action instead of sign in`() {
        let actions = self.actions(
            source: .oauth,
            authenticatedOAuthWithoutEmail: true)

        #expect(actions.contains {
            $0.0 == "Switch Account..." && $0.1 == .switchAccount(.claude)
        })
        #expect(!actions.contains { $0.0 == "Sign in with Claude Code..." })
    }

    @Test
    func `web session errors show claude relogin action`() {
        let errors = [
            ClaudeWebAPIFetcher.FetchError.unauthorized.localizedDescription,
            ClaudeWebAPIFetcher.FetchError.noSessionKeyFound.localizedDescription,
            ClaudeWebAPIFetcher.FetchError.invalidSessionKey.localizedDescription,
        ]

        for error in errors {
            let actions = self.actions(error: error, source: .web)
            #expect(actions.contains {
                $0.0 == "Re-login at claude.ai" &&
                    $0.1 == .loginToProvider(url: "https://claude.ai/")
            })
        }
    }

    @Test
    func `Cloudflare challenge opens Claude settings instead of relogin`() {
        let actions = self.actions(error: Self.cloudflareChallengeMessage, source: .web)

        #expect(actions.contains {
            $0.0 == "Open Claude Settings…" && $0.1 == .providerSettings(.claude)
        })
        #expect(!actions.contains { $0.0 == "Re-login at claude.ai" })
    }

    @Test
    func `unreadable OAuth credentials open Claude settings`() {
        let actions = self.actions(
            error: ClaudeOAuthUnreadableCredentialsError.descriptionPrefix,
            source: .oauth)

        #expect(actions.contains {
            $0.0 == "Allow reading Claude Code's credentials in Settings…" &&
                $0.1 == .providerSettings(.claude)
        })
    }

    @Test
    func `auto source Cloudflare challenge opens Claude settings`() {
        let actions = self.actions(error: Self.cloudflareChallengeMessage, source: .auto)

        #expect(actions.contains {
            $0.0 == "Open Claude Settings…" && $0.1 == .providerSettings(.claude)
        })
        #expect(!actions.contains { $0.0 == "Re-login at claude.ai" })
    }

    @Test
    func `auto source shows relogin action for terminal web session error`() {
        let actions = self.actions(
            error: ClaudeWebAPIFetcher.FetchError.unauthorized.localizedDescription,
            source: .auto)

        #expect(actions.contains {
            $0.0 == "Re-login at claude.ai" &&
                $0.1 == .loginToProvider(url: "https://claude.ai/")
        })
    }

    @Test
    func `non-web source does not replace account action`() {
        let actions = self.actions(
            error: ClaudeWebAPIFetcher.FetchError.unauthorized.localizedDescription,
            source: .oauth)

        #expect(!actions.contains { $0.0 == "Re-login at claude.ai" })
    }

    @Test
    func `manual cookies do not show browser relogin action`() {
        let actions = self.actions(
            error: ClaudeWebAPIFetcher.FetchError.unauthorized.localizedDescription,
            source: .web,
            cookieSource: .manual)

        #expect(!actions.contains { $0.0 == "Re-login at claude.ai" })
    }

    @Test
    func `selected session account does not show browser relogin action`() {
        let actions = self.actions(
            error: ClaudeWebAPIFetcher.FetchError.unauthorized.localizedDescription,
            source: .web,
            cookieSource: .auto,
            selectedSessionKey: true)

        #expect(!actions.contains { $0.0 == "Re-login at claude.ai" })
    }

    @Test
    func `unavailable web strategy shows relogin action`() {
        let actions = self.actions(
            error: ProviderFetchError.noAvailableStrategy(.claude).localizedDescription,
            source: .web,
            attempts: [
                ProviderFetchAttempt(
                    strategyID: "claude.web",
                    kind: .web,
                    wasAvailable: false,
                    errorDescription: nil),
            ])

        #expect(actions.contains {
            $0.0 == "Re-login at claude.ai" &&
                $0.1 == .loginToProvider(url: "https://claude.ai/")
        })
    }

    @Test
    func `generic unavailable error without web attempt keeps account action`() {
        let actions = self.actions(
            error: ProviderFetchError.noAvailableStrategy(.claude).localizedDescription,
            source: .auto,
            attempts: [
                ProviderFetchAttempt(
                    strategyID: "claude.cli",
                    kind: .cli,
                    wasAvailable: false,
                    errorDescription: nil),
            ])

        #expect(!actions.contains { $0.0 == "Re-login at claude.ai" })
    }

    @Test
    func `unrelated web error does not replace account action`() {
        let actions = self.actions(
            error: ClaudeWebAPIFetcher.FetchError.serverError(statusCode: 500).localizedDescription,
            source: .web)

        #expect(!actions.contains { $0.0 == "Re-login at claude.ai" })
    }
}
