import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct ClaudeWebRecoveryMenuTests {
    @Test
    func `unauthorized error explains how to restore web usage`() {
        #expect(
            ClaudeWebAPIFetcher.FetchError.unauthorized.localizedDescription ==
                "Sign in to claude.ai (or refresh Claude cookies) to load usage data.")
    }

    private func makeSettings() -> SettingsStore {
        let suite = "ClaudeWebRecoveryMenuTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
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
        claudeSwapAccountCount: Int = 0,
        attempts: [ProviderFetchAttempt] = []) -> [(String, MenuDescriptor.MenuAction)]
    {
        let settings = self.makeSettings()
        settings.claudeUsageDataSource = source
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
        if authenticatedAccountEmail != nil || authenticatedOAuthWithoutEmail {
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
        store.lastFetchAttempts[.claude] = attempts

        return MenuDescriptor.build(
            provider: .claude,
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updateReady: false)
            .sections
            .flatMap(\.entries)
            .compactMap { entry in
                guard case let .action(label, action) = entry else { return nil }
                return (label, action)
            }
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
