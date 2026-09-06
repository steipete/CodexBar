import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ClaudeCredentialQuotaWarningTests {
    private final class NotifierSpy: SessionQuotaNotifying {
        var thresholds: [Int] = []

        func post(transition _: SessionQuotaTransition, provider _: UsageProvider, badge _: NSNumber?) {}

        func postQuotaWarning(
            event: QuotaWarningEvent,
            provider _: UsageProvider,
            soundEnabled _: Bool,
            onScreenAlertEnabled _: Bool)
        {
            self.thresholds.append(event.threshold)
        }
    }

    @Test(arguments: [true, false])
    func `credential rewrites preserve known account threshold episodes`(hasActiveAccount: Bool) async throws {
        try await self.checkRefreshes(
            activeAccount: hasActiveAccount ? "fixture-account-a" : nil,
            historyOwner: "fixture-oauth-owner",
            expectedThresholds: [50, 50, 20])
    }

    @Test
    func `credential rewrites retire unknown account threshold episodes`() async throws {
        try await self.checkRefreshes(
            activeAccount: nil,
            historyOwner: nil,
            expectedThresholds: [50, 50, 50, 50, 20])
    }

    private func checkRefreshes(
        activeAccount: String?,
        historyOwner: String?,
        expectedThresholds: [Int]) async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCredentialQuotaWarningTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["HOME": root.path, "CLAUDE_CONFIG_DIR": root.path]
        let settings = try self.makeSettings(root: root)
        defer { settings.configFileWatcher?.stop() }
        let notifier = NotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier,
            startupBehavior: .testing,
            environmentBase: environment)
        let otherAccount = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .session, accountDiscriminator: "other-account")
        let otherProvider = UsageStore.QuotaWarningStateKey(
            provider: .deepseek, window: .session, accountDiscriminator: nil)
        for key in [otherAccount, otherProvider] {
            store.quotaWarningState[key] = UsageStore.QuotaWarningState(lastRemaining: 40, firedThresholds: [50])
        }
        let file = root.appendingPathComponent("credentials.json")
        let pending = ClaudeOAuthCredentialsStore.PendingCacheClearMemoryStore()
        try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
            try await ClaudeOAuthCredentialsStore.withPendingCacheClearStoreOverrideForTesting(pending) { @Sendable in
                try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting { @Sendable in
                    try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting { @Sendable in
                        try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(file) { @Sendable in
                            try await UsageStore.withActiveClaudeAccountUuidForTesting(activeAccount) { @MainActor in
                                for (index, remaining) in [60.0, 49, 48, 47, 60, 49, 19].enumerated() {
                                    // A size change proves a fresh fingerprint without filesystem timing assumptions.
                                    let credentials: [String: Any] = ["claudeAiOauth": [
                                        "accessToken": "fixture-" + String(repeating: "x", count: index + 1),
                                        "expiresAt": 1_900_020_000_000,
                                        "scopes": ["user:profile", "user:inference"],
                                    ]]
                                    try JSONSerialization.data(withJSONObject: credentials).write(to: file)
                                    let snapshot = UsageSnapshot(
                                        primary: RateWindow(
                                            usedPercent: 100 - remaining,
                                            windowMinutes: 300,
                                            resetsAt: Date(timeIntervalSince1970: 1_900_020_000),
                                            resetDescription: nil),
                                        secondary: nil,
                                        updatedAt: Date(timeIntervalSince1970: 1_900_000_000 + Double(index)))
                                    let outcome = ProviderFetchOutcome(
                                        result: .success(ProviderFetchResult(
                                            usage: snapshot,
                                            credits: nil,
                                            dashboard: nil,
                                            sourceLabel: "oauth",
                                            strategyID: "fixture.oauth",
                                            strategyKind: .oauth,
                                            claudeOAuthHistoryOwnerIdentifier: historyOwner,
                                            claudeOAuthCredentialOwner: .claudeCLI)),
                                        attempts: [])
                                    store._test_providerFetchOutcomeOverride = { _ in outcome }
                                    await store.refreshProvider(.claude, allowDisabled: true)
                                    #expect(store.snapshot(for: .claude)?.primary?.remainingPercent == remaining)
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(notifier.thresholds == expectedThresholds)
        #expect(store.quotaWarningState[otherAccount]?.firedThresholds == [50])
        #expect(store.quotaWarningState[otherProvider]?.firedThresholds == [50])
    }

    private func makeSettings(root: URL) throws -> SettingsStore {
        let defaults = InMemoryUserDefaults()
        defaults.set(false, forKey: "openAIWebAccessEnabled")
        let config = CodexBarConfigStore(fileURL: root.appendingPathComponent("config.json"))
        try config.save(testConfigWithAllProvidersDisabled())
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: config,
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
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.claudeUsageDataSource = .oauth
        settings.claudeOAuthKeychainPromptMode = .never
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50, 20]
        settings.setQuotaWarningWindowEnabled(.session, enabled: true)
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: false)
        settings.sessionQuotaNotificationsEnabled = false
        settings.predictivePaceWarningNotificationsEnabled = false
        return settings
    }
}
