import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ClaudeCredentialQuotaWarningTests {
    private final class NotifierSpy: SessionQuotaNotifying {
        var thresholds: [Int] = []
        var windows: [QuotaWarningWindow] = []

        func post(transition _: SessionQuotaTransition, provider _: UsageProvider, badge _: NSNumber?) {}

        func postQuotaWarning(
            event: QuotaWarningEvent,
            provider _: UsageProvider,
            soundEnabled _: Bool,
            onScreenAlertEnabled _: Bool)
        {
            self.thresholds.append(event.threshold)
            self.windows.append(event.window)
        }
    }

    @Test(arguments: [true, false])
    func `weekly OAuth fallback does not notify or rearm the session lane`(weeklyOnly: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeWeeklyQuotaWarningTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["HOME": root.path, "CLAUDE_CONFIG_DIR": root.path]
        let settings = try self.makeSettings(root: root)
        defer { settings.configFileWatcher?.stop() }
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: true)
        let notifier = NotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier,
            startupBehavior: .testing,
            environmentBase: environment)
        let sessionUsage: [Double?] = weeklyOnly ? [nil] : [51, nil, 52, 81]
        for used in sessionUsage {
            var payload: [String: Any] = ["seven_day": ["utilization": weeklyOnly ? 95 : 20]]
            payload["five_hour"] = used.map { ["utilization": $0] }
            let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(JSONSerialization.data(withJSONObject: payload))
            let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
            #expect(snapshot.primary?.windowMinutes == (used == nil ? 10080 : 300))
            store.handleQuotaWarningTransitions(
                provider: .claude, snapshot: snapshot, accountDiscriminator: "fixture-account-a")
        }
        #expect(notifier.thresholds == (weeklyOnly ? [20] : [50, 20]))
        #expect(notifier.windows == (weeklyOnly ? [.weekly] : [.session, .session]))
    }

    @Test(arguments: [true, false])
    func `credential rewrites preserve known account threshold episodes`(hasActiveAccount: Bool) async throws {
        try await self.checkRefreshes(
            activeAccount: hasActiveAccount ? "fixture-account-a" : nil,
            historyOwner: "fixture-oauth-owner",
            expectedThresholds: [50, 50, 20])
    }

    @Test(arguments: [ProviderFetchKind.oauth, .cli], [true, false])
    func `credential rewrites preserve unresolved account warnings`(
        strategyKind: ProviderFetchKind, recovers: Bool)
        async throws
    {
        try await self.checkRefreshes(
            activeAccount: nil,
            historyOwner: nil,
            expectedThresholds: recovers ? [50, 50, 20] : [50, 20],
            strategyKind: strategyKind,
            remainingSamples: recovers ? [60, 49, 48, 47, 60, 49, 19] : [60, 49, 48, 47, 19, 18])
    }

    @Test(arguments: [ProviderFetchKind.oauth, .cli])
    func `unresolved history migrates to a stable account without repeating a threshold`(
        strategyKind: ProviderFetchKind) throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUnresolvedWarningTests-\(UUID())", isDirectory: true)
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
        let unknownKey = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .session, accountDiscriminator: "claude-account:unknown", windowID: nil)
        let accountKey = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .session, accountDiscriminator: "claude-account:account-a", windowID: nil)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        store.quotaWarningState[accountKey] = UsageStore.QuotaWarningState(
            lastRemaining: 60, observedAt: now.addingTimeInterval(-1))
        for (index, remaining) in [49.0, 48, 47, 19].enumerated() {
            let scopes = store.warningClaudeAccountDiscriminators(
                strategyKind: strategyKind,
                observation: index < 2 ? .changed : .stable(identity: "account-a"))
            store.handleQuotaWarningTransitions(
                provider: .claude,
                snapshot: UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 100 - remaining, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    updatedAt: now.addingTimeInterval(Double(index))),
                accountDiscriminator: scopes.quota,
                hookAccountDiscriminator: scopes.source,
                requiresKnownAccount: true)
            #expect(notifier.thresholds == (index == 3 ? [50, 20] : [50]))
            #expect((store.quotaWarningState[unknownKey] != nil) == (index < 2))
        }
        #expect(store.quotaWarningState[accountKey]?.firedThresholds == [50, 20])
    }

    @Test
    func `verified OAuth owner and active identity share threshold episodes across CLI fallback`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeWarningIdentityTests-\(UUID())", isDirectory: true)
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
        store.persistClaudeOAuthAccountUuidMap([
            "owner-a": "account-a", "rotated-owner-a": "account-a",
        ])
        let samples: [(Double, ProviderFetchKind, UsageStore.ClaudeOAuthActiveAccountObservation, String?)] = [
            (60, .oauth, .stable(identity: nil), "owner-a"),
            (49, .oauth, .stable(identity: nil), "owner-a"),
            (48, .oauth, .stable(identity: "account-a"), "owner-a"),
            (47, .cli, .stable(identity: "account-a"), nil),
            (46, .cli, .stable(identity: nil), nil),
            (45, .oauth, .changed, "owner-a"),
            (44, .oauth, .stable(identity: nil), "owner-a"),
            (43, .oauth, .stable(identity: "account-a"), "rotated-owner-a"),
            (19, .cli, .stable(identity: "account-a"), nil),
            (60, .cli, .stable(identity: "account-a"), nil),
            (49, .oauth, .stable(identity: "account-a"), "rotated-owner-a"),
            (48, .oauth, .stable(identity: "account-b"), "owner-b"),
            (47, .cli, .stable(identity: "account-a"), nil),
        ]
        for (remaining, kind, observation, owner) in samples {
            let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(JSONSerialization.data(withJSONObject: [
                "five_hour": ["utilization": 100 - remaining],
            ]))
            let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
            let discriminator = store.warningClaudeAccountDiscriminators(
                strategyKind: kind, observation: observation, oauthHistoryOwnerIdentifier: owner).quota
            if let discriminator {
                store.handleQuotaWarningTransitions(
                    provider: .claude, snapshot: snapshot, accountDiscriminator: discriminator)
            }
        }
        // The first ownerless CLI sample starts a fallback episode; resolving it must not warn again.
        #expect(notifier.thresholds == [50, 50, 20, 50, 50])
        #expect(store.warningClaudeAccountDiscriminators(
            strategyKind: .oauth,
            observation: .stable(identity: nil),
            oauthHistoryOwnerIdentifier: "owner-a").quota == "claude-account:account-a")
        #expect(store.warningClaudeAccountDiscriminators(
            strategyKind: .oauth,
            observation: .stable(identity: "account-b"),
            oauthHistoryOwnerIdentifier: "owner-a").quota == nil)
    }

    @Test(arguments: [true, false])
    func `verified owner migration preserves the latest recovery and other warning lanes`(ownerIsNewest: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeWarningMigrationTests-\(UUID())", isDirectory: true)
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
        settings.setHooksEnabled(true)
        settings.addHookRule(HookRule(
            event: .quotaLow,
            provider: UsageProvider.claude.rawValue,
            threshold: 0.95,
            executable: "/usr/bin/true"))
        store.resetQuotaLowHookUsageIfConfigurationChanged()
        let owner = "claude-oauth-owner:owner-a"
        let account = "claude-account:account-a"
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let ownerKey = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .session, accountDiscriminator: owner, windowID: nil)
        let accountKey = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .session, accountDiscriminator: account, windowID: nil)
        let older = UsageStore.QuotaWarningState(lastRemaining: 49, observedAt: now, firedThresholds: [50])
        let newer = UsageStore.QuotaWarningState(lastRemaining: 60, observedAt: now.addingTimeInterval(1))
        store.quotaWarningState[ownerKey] = ownerIsNewest ? newer : older
        store.quotaWarningState[accountKey] = ownerIsNewest ? older : newer
        store.quotaLowHookUsage[ownerKey] = 0.4
        store.quotaLowHookUsage[accountKey] = 0.9
        let predictive = PredictivePaceWarningStateKey(
            provider: .claude,
            accountDiscriminator: owner,
            window: .session,
            resetWindow: PredictivePaceWarningResetWindow(windowMinutes: 300, resetsAt: now.addingTimeInterval(100)))
        store.predictivePaceWarningNotifiedKeys.insert(predictive)
        store.persistClaudeOAuthAccountUuidMap(["owner-a": "account-a"])

        let scopes = store.warningClaudeAccountDiscriminators(
            strategyKind: .oauth,
            observation: .stable(identity: nil),
            oauthHistoryOwnerIdentifier: "owner-a")
        #expect(scopes.quota == account)
        #expect(scopes.source == owner)
        #expect(store.quotaWarningState[ownerKey] == nil)
        #expect(store.quotaWarningState[accountKey]?.firedThresholds.isEmpty == true)
        #expect(store.quotaWarningState[accountKey]?.lastRemaining == 60)
        #expect(store.quotaLowHookUsage[ownerKey] == 0.4)
        #expect(store.quotaLowHookUsage[accountKey] == 0.9)
        #expect(store.predictivePaceWarningNotifiedKeys.map(\.accountDiscriminator) == [owner])
        store.handleQuotaWarningTransitions(
            provider: .claude,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 51, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: now.addingTimeInterval(2)),
            accountDiscriminator: scopes.quota,
            hookAccountDiscriminator: scopes.source)
        #expect(notifier.thresholds == [50])
        #expect(store.quotaLowHookUsage[ownerKey] == 0.51)
        #expect(store.quotaLowHookUsage[accountKey] == 0.9)
    }

    private func checkRefreshes(
        activeAccount: String?,
        historyOwner: String?,
        expectedThresholds: [Int],
        strategyKind: ProviderFetchKind = .oauth,
        remainingSamples: [Double] = [60, 49, 48, 47, 60, 49, 19]) async throws
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
            provider: .claude, window: .session, accountDiscriminator: "other-account", windowID: nil)
        let otherProvider = UsageStore.QuotaWarningStateKey(
            provider: .deepseek, window: .session, accountDiscriminator: nil, windowID: nil)
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
                                for (index, remaining) in remainingSamples.enumerated() {
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
                                            sourceLabel: strategyKind == .cli ? "claude" : "oauth",
                                            strategyID: "fixture.usage",
                                            strategyKind: strategyKind,
                                            claudeOAuthHistoryOwnerIdentifier: historyOwner,
                                            claudeOAuthCredentialOwner: strategyKind == .oauth ? .claudeCLI : nil)),
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
