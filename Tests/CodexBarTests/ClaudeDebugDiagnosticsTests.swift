import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeDebugDiagnosticsTests {
    private func makeCredentialsData(
        accessToken: String,
        expiresAt: Date,
        refreshToken: String? = nil) -> Data
    {
        let refreshTokenLine = if let refreshToken {
            """
                "refreshToken": "\(refreshToken)",
            """
        } else {
            ""
        }
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
        \(refreshTokenLine)
            "expiresAt": \(Int(expiresAt.timeIntervalSince1970 * 1000)),
            "scopes": ["user:profile"]
          }
        }
        """
        return Data(json.utf8)
    }

    @Test
    func `debug log uses planner derived order and reasons`() async throws {
        let suite = "ClaudeDebugDiagnosticsTests-\(UUID().uuidString)"
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let credentialsURL = tempDir.appendingPathComponent("credentials.json")
        let credsJSON = """
        {
          "claudeAiOauth": {
            "accessToken": "oauth-token",
            "expiresAt": \(Int(Date(timeIntervalSinceNow: 3600).timeIntervalSince1970 * 1000)),
            "scopes": ["user:profile"]
          }
        }
        """
        try Data(credsJSON.utf8).write(to: credentialsURL)

        let store = try await MainActor.run { () -> UsageStore in
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let configStore = testConfigStore(suiteName: suite)
            let settings = SettingsStore(
                userDefaults: defaults,
                configStore: configStore,
                zaiTokenStore: NoopZaiTokenStore())
            settings.claudeUsageDataSource = .auto
            settings.claudeCookieSource = .manual
            settings.claudeCookieHeader = "sessionKey=sk-ant-session-token"

            return UsageStore(
                fetcher: UsageFetcher(),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings)
        }

        let text = await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            return await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(credentialsURL) {
                        await store.debugLog(for: .claude)
                    }
                }
            }
        }

        #expect(text.contains("planner_order=oauth→cli→web"))
        #expect(text.contains("planner_selected=oauth"))
        #expect(text.contains("planner_no_source=false"))
        #expect(text.contains("planner_step.oauth=available reason=app-auto-preferred-oauth"))
        #expect(text.contains("planner_step.cli="))
        #expect(text.contains("reason=app-auto-fallback-cli"))
        #expect(text.contains("planner_step.web=available reason=app-auto-fallback-web"))
        #expect(!text.contains("auto_heuristic="))
    }

    @Test
    func `debug log reports no planner selected source when auto has no available sources`() async throws {
        let suite = "ClaudeDebugDiagnosticsTests-\(UUID().uuidString)"
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let missingCredentialsURL = tempDir.appendingPathComponent("missing-credentials.json")

        let store = try await MainActor.run { () -> UsageStore in
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let configStore = testConfigStore(suiteName: suite)
            let settings = SettingsStore(
                userDefaults: defaults,
                configStore: configStore,
                zaiTokenStore: NoopZaiTokenStore())
            settings.claudeUsageDataSource = .auto
            settings.claudeCookieSource = .off
            settings.claudeWebExtrasEnabled = true

            return UsageStore(
                fetcher: UsageFetcher(),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings)
        }

        let text = await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/definitely/missing/claude") {
            await KeychainCacheStore.withServiceOverrideForTesting(service) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                return await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                        await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(missingCredentialsURL) {
                            await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                                await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                    data: nil,
                                    fingerprint: nil)
                                {
                                    await store.debugLog(for: .claude)
                                }
                            }
                        }
                    }
                }
            }
        }

        #expect(text.contains("planner_selected=none"))
        #expect(text.contains("planner_no_source=true"))
        #expect(text.contains("No planner-selected Claude source."))
        #expect(!text.contains("web_extras=enabled"))
    }

    @Test
    func `debug Claude dump returns recorded parse dumps`() async {
        await ClaudeStatusProbe._replaceDumpsForTesting([
            "dump one",
            "dump two",
        ])

        let store = await MainActor.run {
            UsageStore(
                fetcher: UsageFetcher(),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: SettingsStore(
                    userDefaults: UserDefaults(),
                    configStore: testConfigStore(suiteName: "ClaudeDebugDiagnosticsTests-\(UUID().uuidString)"),
                    zaiTokenStore: NoopZaiTokenStore()))
        }
        let text = await store.debugClaudeDump()

        #expect(text.contains("dump one"))
        #expect(text.contains("dump two"))
        #expect(!text.contains("planner_order="))
        await ClaudeStatusProbe._replaceDumpsForTesting([])
    }

    @Test
    func `debug log uses runtime OAuth availability for token account routing`() async throws {
        let suite = "ClaudeDebugDiagnosticsTests-\(UUID().uuidString)"
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let missingCredentialsURL = tempDir.appendingPathComponent("missing-credentials.json")

        let store = try await MainActor.run { () -> UsageStore in
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let configStore = testConfigStore(suiteName: suite)
            let settings = SettingsStore(
                userDefaults: defaults,
                configStore: configStore,
                zaiTokenStore: NoopZaiTokenStore())
            settings.claudeUsageDataSource = .auto
            settings.claudeCookieSource = .off
            settings.addTokenAccount(
                provider: .claude,
                label: "OAuth Account",
                token: "sk-ant-oat-test-token")

            return UsageStore(
                fetcher: UsageFetcher(),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings)
        }

        let text = await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/definitely/missing/claude") {
            await KeychainCacheStore.withServiceOverrideForTesting(service) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                return await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                        await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(missingCredentialsURL) {
                            await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                                await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                    data: nil,
                                    fingerprint: nil)
                                {
                                    await store.debugLog(for: .claude)
                                }
                            }
                        }
                    }
                }
            }
        }

        #expect(text.contains("planner_selected=oauth"))
        #expect(text.contains("hasOAuthCredentials=true"))
        #expect(text.contains("oauthCredentialOwner=environment"))
        #expect(text.contains("oauthCredentialSource=environment"))
        #expect(!text.contains("planner_selected=none"))
    }

    @Test
    func `debug log preserves CLI probe overrides across detached work`() async throws {
        let suite = "ClaudeDebugDiagnosticsTests-\(UUID().uuidString)"
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let missingCredentialsURL = tempDir.appendingPathComponent("missing-credentials.json")
        let store = try await MainActor.run { () -> UsageStore in
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let configStore = testConfigStore(suiteName: suite)
            let settings = SettingsStore(
                userDefaults: defaults,
                configStore: configStore,
                zaiTokenStore: NoopZaiTokenStore())
            settings.claudeUsageDataSource = .cli
            settings.claudeCookieSource = .off

            return UsageStore(
                fetcher: UsageFetcher(),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings)
        }

        let fetchOverride: ClaudeStatusProbe.FetchOverride = { resolved, _, _ in
            #expect(resolved == "/usr/bin/true")
            return ClaudeStatusSnapshot(
                sessionPercentLeft: 76,
                weeklyPercentLeft: 55,
                opusPercentLeft: nil,
                accountEmail: "cli@example.com",
                accountOrganization: "CLI Org",
                loginMethod: "cli",
                primaryResetDescription: "Mar 7 at 1pm",
                secondaryResetDescription: nil,
                opusResetDescription: nil,
                rawText: "probe raw")
        }

        let text = await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
            await KeychainCacheStore.withServiceOverrideForTesting(service) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                return await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                        await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(missingCredentialsURL) {
                            await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                                await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                    data: nil,
                                    fingerprint: nil)
                                {
                                    await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                                        await store.debugLog(for: .claude)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        #expect(text.contains("planner_selected=cli"))
        #expect(text.contains("session_left=76.0 weekly_left=55.0"))
        #expect(text.contains("email cli@example.com"))
    }

    @Test
    func `debug log uses user initiated interaction for OAuth prompt gate`() async throws {
        let suite = "ClaudeDebugDiagnosticsTests-\(UUID().uuidString)"
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let missingCredentialsURL = tempDir.appendingPathComponent("missing-credentials.json")
        let securityData = self.makeCredentialsData(
            accessToken: "user-initiated-oauth",
            expiresAt: Date(timeIntervalSinceNow: 3600))
        let deniedStore = ClaudeOAuthKeychainAccessGate.DeniedUntilStore()
        deniedStore.deniedUntil = Date(timeIntervalSinceNow: 300)

        let store = try await MainActor.run { () -> UsageStore in
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let configStore = testConfigStore(suiteName: suite)
            let settings = SettingsStore(
                userDefaults: defaults,
                configStore: configStore,
                zaiTokenStore: NoopZaiTokenStore())
            settings.claudeUsageDataSource = .auto
            settings.claudeCookieSource = .off

            return UsageStore(
                fetcher: UsageFetcher(),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings)
        }

        let text = await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/definitely/missing/claude") {
            await KeychainCacheStore.withServiceOverrideForTesting(service) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                return await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                        await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(missingCredentialsURL) {
                            await ClaudeOAuthKeychainAccessGate.withDeniedUntilStoreOverrideForTesting(deniedStore) {
                                await ClaudeOAuthKeychainPromptPreference
                                    .withTaskOverrideForTesting(.onlyOnUserAction) {
                                        await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                                            .securityCLIExperimental)
                                        {
                                            await ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                                .data(securityData))
                                            {
                                                await ProviderInteractionContext.$current.withValue(.userInitiated) {
                                                    await store.debugLog(for: .claude)
                                                }
                                            }
                                        }
                                    }
                            }
                        }
                    }
                }
            }
        }

        #expect(text.contains("planner_selected=oauth"))
        #expect(text.contains("hasOAuthCredentials=true"))
    }

    @Test
    func `debug log invalidates cached planner output when Claude settings change`() async throws {
        let suite = "ClaudeDebugDiagnosticsTests-\(UUID().uuidString)"
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let missingCredentialsURL = tempDir.appendingPathComponent("missing-credentials.json")
        let storeAndSettings = try await MainActor.run { () -> (UsageStore, SettingsStore) in
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let configStore = testConfigStore(suiteName: suite)
            let settings = SettingsStore(
                userDefaults: defaults,
                configStore: configStore,
                zaiTokenStore: NoopZaiTokenStore())
            settings.claudeUsageDataSource = .cli
            settings.claudeCookieSource = .off

            let store = UsageStore(
                fetcher: UsageFetcher(),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings)
            return (store, settings)
        }
        let store = storeAndSettings.0
        let settings = storeAndSettings.1
        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, _, _ in
            ClaudeStatusSnapshot(
                sessionPercentLeft: 80,
                weeklyPercentLeft: 60,
                opusPercentLeft: nil,
                accountEmail: "cache@example.com",
                accountOrganization: nil,
                loginMethod: "cli",
                primaryResetDescription: "Mar 7 at 1pm",
                secondaryResetDescription: nil,
                opusResetDescription: nil,
                rawText: "probe raw")
        }

        let first = await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
            await KeychainCacheStore.withServiceOverrideForTesting(service) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                return await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                        await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(missingCredentialsURL) {
                            await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(false) {
                                await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                    data: nil,
                                    fingerprint: nil)
                                {
                                    await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                                        await store.debugLog(for: .claude)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        await MainActor.run {
            settings.claudeUsageDataSource = .auto
        }
        await Task.yield()
        await Task.yield()

        let second = await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/definitely/missing/claude") {
            await KeychainCacheStore.withServiceOverrideForTesting(service) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                return await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                        await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(missingCredentialsURL) {
                            await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                                await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                    data: nil,
                                    fingerprint: nil)
                                {
                                    await store.debugLog(for: .claude)
                                }
                            }
                        }
                    }
                }
            }
        }

        #expect(first.contains("planner_selected=cli"))
        #expect(second.contains("planner_selected=none"))
    }
}
