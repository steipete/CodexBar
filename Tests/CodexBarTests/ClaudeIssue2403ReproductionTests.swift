import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct ClaudeIssue2403ReproductionTests {
    private func makeSettings(suiteSuffix: String) -> SettingsStore {
        let suite = "ClaudeIssue2403ReproductionTests-\(suiteSuffix)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    @Test
    func `login flow succeeds but subsequent web source refresh fails with unauthorized leading to immediate disconnect`() async throws {
        let registry = ProviderRegistry.shared
        let claudeMetadata = try #require(registry.metadata[.claude])

        let settings = self.makeSettings(suiteSuffix: "web-unauthorized")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.providerDetectionCompleted = true
        settings.claudeUsageDataSource = .web
        settings.setProviderEnabled(provider: .claude, metadata: claudeMetadata, enabled: false)

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        // 1. Simulate user clicking "Sign in with Claude Code..." which runs login runner and succeeds
        await withStatusItemControllerForTesting(store: store, settings: settings, fetcher: fetcher) { controller in
            let didLogin = await controller.runClaudeLoginFlow { _, onPhaseChange in
                onPhaseChange(.requesting)
                await Task.yield()
                onPhaseChange(.waitingBrowser)
                await Task.yield()
                return ClaudeLoginRunner.Result(
                    outcome: .success,
                    output: "Successfully logged in",
                    authLink: nil)
            }

            #expect(didLogin)
            #expect(settings.isProviderEnabledCached(provider: .claude, metadataByProvider: registry.metadata))
        }

        // 2. Immediately after login, store refreshes provider.
        // If web API is unauthorized (e.g. browser not logged in), web fetch fails with unauthorized
        store.errors[.claude] = ClaudeWebAPIFetcher.FetchError.unauthorized.localizedDescription

        // 3. Verify menu actions immediately revert to re-login / disconnect state
        let actions = MenuDescriptor.build(
            provider: .claude,
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updateReady: false)
            .sections
            .flatMap(\.entries)
            .compactMap { entry -> (String, MenuDescriptor.MenuAction)? in
                guard case let .action(label, action) = entry else { return nil }
                return (label, action)
            }

        #expect(actions.contains {
            $0.0 == "Re-login at claude.ai" && $0.1 == .loginToProvider(url: "https://claude.ai/")
        })
    }

    @Test
    func `login flow succeeds but stale token account causes immediate refresh failure and disconnect`() async throws {
        let registry = ProviderRegistry.shared
        let claudeMetadata = try #require(registry.metadata[.claude])

        let settings = self.makeSettings(suiteSuffix: "token-account-stale")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.providerDetectionCompleted = true
        settings.claudeUsageDataSource = .auto

        // User previously configured a stale/invalid token account
        settings.addTokenAccount(provider: .claude, label: "Old Account", token: "invalid-cookie-session-token")
        settings.setProviderEnabled(provider: .claude, metadata: claudeMetadata, enabled: false)

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        // 1. User signs in with Claude Code CLI
        await withStatusItemControllerForTesting(store: store, settings: settings, fetcher: fetcher) { controller in
            let didLogin = await controller.runClaudeLoginFlow { _, onPhaseChange in
                onPhaseChange(.requesting)
                await Task.yield()
                return ClaudeLoginRunner.Result(
                    outcome: .success,
                    output: "Logged in successfully",
                    authLink: nil)
            }

            #expect(didLogin)
        }

        // 2. Token account override causes fetch to fail on refresh
        store.errors[.claude] = "Claude session key invalid"

        withStatusItemControllerForTesting(store: store, settings: settings, fetcher: fetcher) { controller in
            let model = controller.menuCardModel(for: .claude)
            #expect(model?.subtitleStyle == .error)
            #expect(model?.subtitleText == "Claude session key invalid")
        }
    }

    @Test
    func `oauth unauthorized error after login forces terminal re-auth prompt`() {
        let settings = self.makeSettings(suiteSuffix: "oauth-unauthorized")
        settings.claudeUsageDataSource = .oauth

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        store.errors[.claude] = ClaudeOAuthFetchError.unauthorized.localizedDescription

        let actions = MenuDescriptor.build(
            provider: .claude,
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updateReady: false)
            .sections
            .flatMap(\.entries)
            .compactMap { entry -> (String, MenuDescriptor.MenuAction)? in
                guard case let .action(label, action) = entry else { return nil }
                return (label, action)
            }

        #expect(actions.contains {
            $0.0 == "Open Terminal" && $0.1 == .openTerminal(command: "claude")
        })
    }
}
