import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
@Suite(.serialized)
struct ClaudeOAuthFetchStrategyAvailabilityTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    private func makeContext(
        sourceMode: ProviderSourceMode,
        env: [String: String] = [:]) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    private func expiredRecord(owner: ClaudeOAuthCredentialOwner = .claudeCLI) -> ClaudeOAuthCredentialRecord {
        ClaudeOAuthCredentialRecord(
            credentials: ClaudeOAuthCredentials(
                accessToken: "expired-token",
                refreshToken: "refresh-token",
                expiresAt: Date(timeIntervalSinceNow: -60),
                scopes: ["user:profile"],
                rateLimitTier: nil),
            owner: owner,
            source: .cacheKeychain)
    }

    @Test
    func `auto mode expired creds cli available returns available`() async {
        let context = self.makeContext(sourceMode: .auto)
        let strategy = ClaudeOAuthFetchStrategy()
        let available = await ClaudeOAuthFetchStrategy.$nonInteractiveCredentialRecordOverride
            .withValue(self.expiredRecord()) {
                await ClaudeOAuthFetchStrategy.$claudeCLIAvailableOverride.withValue(true) {
                    await strategy.isAvailable(context)
                }
            }
        #expect(available == true)
    }

    @Test
    func `auto mode expired creds cli unavailable returns unavailable`() async {
        let context = self.makeContext(sourceMode: .auto)
        let strategy = ClaudeOAuthFetchStrategy()
        let available = await ClaudeOAuthFetchStrategy.$nonInteractiveCredentialRecordOverride
            .withValue(self.expiredRecord()) {
                await ClaudeOAuthFetchStrategy.$claudeCLIAvailableOverride.withValue(false) {
                    await strategy.isAvailable(context)
                }
            }
        #expect(available == false)
    }

    @Test
    func `oauth mode expired creds cli available returns available`() async {
        let context = self.makeContext(sourceMode: .oauth)
        let strategy = ClaudeOAuthFetchStrategy()
        let available = await ClaudeOAuthFetchStrategy.$nonInteractiveCredentialRecordOverride
            .withValue(self.expiredRecord()) {
                await ClaudeOAuthFetchStrategy.$claudeCLIAvailableOverride.withValue(true) {
                    await strategy.isAvailable(context)
                }
            }
        #expect(available == true)
    }

    @Test
    func `auto mode expired codexbar creds cli unavailable still available`() async {
        let context = self.makeContext(sourceMode: .auto)
        let strategy = ClaudeOAuthFetchStrategy()
        let available = await ClaudeOAuthFetchStrategy.$nonInteractiveCredentialRecordOverride
            .withValue(self.expiredRecord(owner: .codexbar)) {
                await ClaudeOAuthFetchStrategy.$claudeCLIAvailableOverride.withValue(false) {
                    await strategy.isAvailable(context)
                }
            }
        #expect(available == true)
    }

    @Test
    func `oauth mode does not fallback after O auth failure`() {
        let context = self.makeContext(sourceMode: .oauth)
        let strategy = ClaudeOAuthFetchStrategy()
        #expect(strategy.shouldFallback(
            on: ClaudeUsageError.oauthFailed("oauth failed"),
            context: context) == false)
    }

    @Test
    func `auto mode falls back after O auth failure`() {
        let context = self.makeContext(sourceMode: .auto)
        let strategy = ClaudeOAuthFetchStrategy()
        #expect(strategy.shouldFallback(
            on: ClaudeUsageError.oauthFailed("oauth failed"),
            context: context) == true)
    }

    @Test
    func `auto mode user initiated clears keychain cooldown gate`() async {
        let context = self.makeContext(sourceMode: .auto)
        let strategy = ClaudeOAuthFetchStrategy()
        let recordWithoutRequiredScope = ClaudeOAuthCredentialRecord(
            credentials: ClaudeOAuthCredentials(
                accessToken: "expired-token",
                refreshToken: "refresh-token",
                expiresAt: Date(timeIntervalSinceNow: -60),
                scopes: ["user:inference"],
                rateLimitTier: nil),
            owner: .claudeCLI,
            source: .cacheKeychain)

        await KeychainAccessGate.withTaskOverrideForTesting(false) {
            ClaudeOAuthKeychainAccessGate.resetForTesting()
            defer { ClaudeOAuthKeychainAccessGate.resetForTesting() }

            let now = Date(timeIntervalSince1970: 1000)
            ClaudeOAuthKeychainAccessGate.recordDenied(now: now)
            #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now) == false)

            _ = await ClaudeOAuthFetchStrategy.$nonInteractiveCredentialRecordOverride
                .withValue(recordWithoutRequiredScope) {
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await strategy.isAvailable(context)
                    }
                }

            #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now))
        }
    }

    @Test
    func `auto mode only on user action background startup without cache is available for bootstrap`() async throws {
        let context = self.makeContext(sourceMode: .auto)
        let strategy = ClaudeOAuthFetchStrategy()
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"

        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                ClaudeOAuthCredentialsStore.invalidateCache()
                ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                ClaudeOAuthKeychainAccessGate.resetForTesting()
                defer {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    ClaudeOAuthKeychainAccessGate.resetForTesting()
                }

                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")

                let available = await KeychainAccessGate.withTaskOverrideForTesting(false) {
                    await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(.securityFramework) {
                            await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                                await ProviderRefreshContext.$current.withValue(.startup) {
                                    await ProviderInteractionContext.$current.withValue(.background) {
                                        await strategy.isAvailable(context)
                                    }
                                }
                            }
                        }
                    }
                }

                #expect(available == true)
            }
        }
    }

    @Test
    func `auto mode expired Claude CLI creds env provided CLI override returns available`() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let cliURL = tempDir.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cliURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)

        let context = self.makeContext(
            sourceMode: .auto,
            env: ["CLAUDE_CLI_PATH": cliURL.path])
        let strategy = ClaudeOAuthFetchStrategy()
        let available = await ClaudeOAuthFetchStrategy.$nonInteractiveCredentialRecordOverride
            .withValue(self.expiredRecord()) {
                await strategy.isAvailable(context)
            }

        #expect(available == true)
    }

    @Test
    func `auto mode default reader keeps background startup bootstrap available`() async throws {
        let context = self.makeContext(sourceMode: .auto)
        let strategy = ClaudeOAuthFetchStrategy()
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"

        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                ClaudeOAuthCredentialsStore.invalidateCache()
                ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                ClaudeOAuthKeychainAccessGate.resetForTesting()
                defer {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    ClaudeOAuthKeychainAccessGate.resetForTesting()
                }

                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")

                let available = await KeychainAccessGate.withTaskOverrideForTesting(false) {
                    await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                            await ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.nonZeroExit) {
                                await ProviderRefreshContext.$current.withValue(.startup) {
                                    await ProviderInteractionContext.$current.withValue(.background) {
                                        await strategy.isAvailable(context)
                                    }
                                }
                            }
                        }
                    }
                }

                #expect(available == true)
            }
        }
    }

    @Test
    func `auto mode experimental reader ignores prompt policy cooldown gate`() async {
        let context = self.makeContext(sourceMode: .auto)
        let strategy = ClaudeOAuthFetchStrategy()
        let securityData = Data("""
        {
          "claudeAiOauth": {
            "accessToken": "security-token",
            "expiresAt": \(Int(Date(timeIntervalSinceNow: 3600).timeIntervalSince1970 * 1000)),
            "scopes": ["user:profile"]
          }
        }
        """.utf8)

        let recordWithoutRequiredScope = ClaudeOAuthCredentialRecord(
            credentials: ClaudeOAuthCredentials(
                accessToken: "token-no-scope",
                refreshToken: "refresh-token",
                expiresAt: Date(timeIntervalSinceNow: -60),
                scopes: ["user:inference"],
                rateLimitTier: nil),
            owner: .claudeCLI,
            source: .cacheKeychain)

        let available = await KeychainAccessGate.withTaskOverrideForTesting(false) {
            await ClaudeOAuthKeychainAccessGate.withShouldAllowPromptOverrideForTesting(false) {
                await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                    .securityCLIExperimental)
                {
                    await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                        await ClaudeOAuthFetchStrategy.$nonInteractiveCredentialRecordOverride.withValue(
                            recordWithoutRequiredScope)
                        {
                            await ProviderInteractionContext.$current.withValue(.background) {
                                await ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.data(
                                    securityData))
                                {
                                    await strategy.isAvailable(context)
                                }
                            }
                        }
                    }
                }
            }
        }

        #expect(available == true)
    }

    @Test
    func `auto mode experimental reader security failure blocks availability when stored policy blocks fallback`()
        async
    {
        let context = self.makeContext(sourceMode: .auto)
        let strategy = ClaudeOAuthFetchStrategy()
        let fallbackData = Data("""
        {
          "claudeAiOauth": {
            "accessToken": "fallback-token",
            "expiresAt": \(Int(Date(timeIntervalSinceNow: 3600).timeIntervalSince1970 * 1000)),
            "scopes": ["user:profile"]
          }
        }
        """.utf8)

        let recordWithoutRequiredScope = ClaudeOAuthCredentialRecord(
            credentials: ClaudeOAuthCredentials(
                accessToken: "token-no-scope",
                refreshToken: "refresh-token",
                expiresAt: Date(timeIntervalSinceNow: -60),
                scopes: ["user:inference"],
                rateLimitTier: nil),
            owner: .claudeCLI,
            source: .cacheKeychain)

        let available = await KeychainAccessGate.withTaskOverrideForTesting(false) {
            await ClaudeOAuthKeychainAccessGate.withShouldAllowPromptOverrideForTesting(true) {
                await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                    .securityCLIExperimental)
                {
                    await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                        await ClaudeOAuthFetchStrategy.$nonInteractiveCredentialRecordOverride.withValue(
                            recordWithoutRequiredScope)
                        {
                            await ProviderInteractionContext.$current.withValue(.background) {
                                await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                    data: fallbackData,
                                    fingerprint: nil)
                                {
                                    await ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                        .nonZeroExit)
                                    {
                                        await strategy.isAvailable(context)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        #expect(available == false)
    }
}
#endif
