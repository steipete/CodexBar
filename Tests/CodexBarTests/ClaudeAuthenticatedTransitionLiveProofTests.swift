import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeAuthenticatedTransitionLiveProofTests {
    private static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["LIVE_CLAUDE_KEYCHAIN_PROOF"] == "1" &&
            environment["LIVE_CLAUDE_TRANSITION_PROOF"] == "1"
    }

    @Test
    func `live environment OAuth survives an in flight local account switch`() async throws {
        guard Self.isEnabled else { return }
        let processEnvironment = ProcessInfo.processInfo.environment
        guard processEnvironment[ClaudeOAuthCredentialsStore.environmentTokenKey]?.isEmpty == false else {
            Issue.record("Live transition proof requires an ephemeral CODEXBAR_CLAUDE_OAUTH_TOKEN")
            return
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-live-oauth-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let accountBefore = UUID().uuidString
        let accountAfter = UUID().uuidString
        try Self.writeActiveAccount(accountBefore, to: root)

        var environment = processEnvironment
        environment[ClaudeConfigPaths.configDirectoryEnvironmentKey] = root.path
        environment[KeychainAccessGate.disableAccessEnvironmentKey] = "1"
        let fixture = try await MainActor.run {
            try Self.makeLiveOAuthFixture(environment: environment)
        }

        let refresh = Task { @MainActor in
            await fixture.store.refreshProvider(.claude)
        }
        try await Task.sleep(for: .milliseconds(20))
        try Self.writeActiveAccount(accountAfter, to: root)
        await refresh.value

        let result = await MainActor.run {
            (
                hasSnapshot: fixture.store.snapshot(for: .claude) != nil,
                source: fixture.store.lastSourceLabels[.claude]?.lowercased(),
                error: fixture.store.error(for: .claude),
                persistedIdentity: fixture.settings.userDefaults.string(
                    forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting(
                        environment: environment)))
        }
        #expect(result.hasSnapshot)
        #expect(result.source == "oauth")
        #expect(result.error == nil)
        #expect(result.persistedIdentity == UsageStore._activeClaudeAccountIdentityForTesting(
            accountAfter,
            environment: environment))
    }

    @Test
    func `live cancelled owner fetch preserves and completes the next background Auto fetch`() async throws {
        guard Self.isEnabled else { return }
        let binary = try #require(TTYCommandRunner.which("claude"))
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CLI_PATH"] = binary
        environment[KeychainAccessGate.disableAccessEnvironmentKey] = "1"
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: ClaudeUsageFetcher(
                browserDetection: browserDetection,
                environment: environment),
            browserDetection: browserDetection)
        let strategy = ClaudeCLIFetchStrategy(
            useWebExtras: false,
            includePrepaidBalance: false,
            manualCookieHeader: nil,
            browserDetection: browserDetection,
            hasWebFallback: false)

        _ = try await ProviderInteractionContext.$current.withValue(.userInitiated) {
            try await strategy.fetch(context)
        }
        #expect(await ProviderInteractionContext.$current.withValue(.background) {
            await strategy.isAvailable(context)
        })

        let cancelledFetch = Task {
            try await ProviderInteractionContext.$current.withValue(.background) {
                try await strategy.fetch(context)
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        cancelledFetch.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledFetch.value
        }

        #expect(await ProviderInteractionContext.$current.withValue(.background) {
            await strategy.isAvailable(context)
        })
        let recovered = try await ProviderInteractionContext.$current.withValue(.background) {
            try await strategy.fetch(context)
        }
        #expect(recovered.usage.scoped(to: .claude).primary != nil)
    }

    @MainActor
    private static func makeLiveOAuthFixture(
        environment: [String: String]) throws -> (store: UsageStore, settings: SettingsStore)
    {
        let settings = testSettingsStore(suiteName: "ClaudeAuthenticatedTransitionLiveProofTests")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.claudeUsageDataSource = .oauth
        settings.claudeWebExtrasEnabled = false
        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: provider == .claude)
        }

        let browserDetection = BrowserDetection(cacheTTL: 0)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: browserDetection,
            claudeFetcher: ClaudeUsageFetcher(
                browserDetection: browserDetection,
                environment: environment),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        return (store, settings)
    }

    private static func writeActiveAccount(_ accountID: String, to root: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["oauthAccount": ["accountUuid": accountID]],
            options: [.sortedKeys])
        try data.write(to: root.appendingPathComponent(".config.json"), options: .atomic)
    }
}
