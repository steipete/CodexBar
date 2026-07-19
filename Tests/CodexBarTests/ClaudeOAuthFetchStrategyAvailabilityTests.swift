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
    func `auto mode expired CLI creds remain available after Keychain opt in`() async {
        let context = self.makeContext(sourceMode: .auto)
        let strategy = ClaudeOAuthFetchStrategy()
        let available = await KeychainAccessGate.withTaskOverrideForTesting(false) {
            await self.withAvailabilityKeychainDoubles {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                    await ClaudeOAuthFetchStrategy.$nonInteractiveCredentialRecordOverride
                        .withValue(self.expiredRecord()) {
                            await ClaudeOAuthFetchStrategy.$claudeCLIAvailableOverride.withValue(true) {
                                await strategy.isAvailable(context)
                            }
                        }
                }
            }
        }
        #expect(available == true)
    }

    @Test
    func `auto mode expired CLI creds with MCP-only keychain returns unavailable in background`() async {
        let available = await self.expiredCLIAvailability(
            sourceMode: .auto,
            interaction: .background,
            keychainData: self.mcpOAuthOnlyKeychainPayload)

        #expect(!available)
    }

    @Test
    func `auto mode expired CLI creds with MCP-only keychain remains available for user action`() async {
        let available = await self.expiredCLIAvailability(
            sourceMode: .auto,
            interaction: .userInitiated,
            keychainData: self.mcpOAuthOnlyKeychainPayload)

        #expect(available)
    }

    @Test
    func `explicit O auth keeps expired CLI credentials available with MCP-only keychain`() async {
        let available = await self.expiredCLIAvailability(
            sourceMode: .oauth,
            interaction: .background,
            keychainData: self.mcpOAuthOnlyKeychainPayload)

        #expect(available)
    }

    @Test
    func `stored user action policy blocks expired CLI credentials with experimental reader`() async {
        let available = await self.expiredCLIAvailability(
            sourceMode: .auto,
            interaction: .background,
            keychainData: self.ordinaryOAuthKeychainPayload,
            readStrategy: .securityCLIExperimental)

        #expect(!available)
    }

    @Test
    func `auto mode disables expired Claude CLI credentials when keychain access is disabled`() async {
        let available = await self.expiredCLIAvailability(
            sourceMode: .auto,
            interaction: .background,
            keychainData: self.mcpOAuthOnlyKeychainPayload,
            keychainAccessDisabled: true)

        #expect(!available)
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
                        await self.withAvailabilityKeychainDoubles {
                            await strategy.isAvailable(context)
                        }
                    }
                }

            #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now))
        }
    }

    @Test
    func `auto mode only on user action background startup without cache is unavailable`() async throws {
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
                                await self.withAvailabilityKeychainDoubles {
                                    await ProviderRefreshContext.$current.withValue(.startup) {
                                        await ProviderInteractionContext.$current.withValue(.background) {
                                            await strategy.isAvailable(context)
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
        let available = await KeychainAccessGate.withTaskOverrideForTesting(false) {
            await self.withAvailabilityKeychainDoubles {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                    await ClaudeOAuthFetchStrategy.$nonInteractiveCredentialRecordOverride
                        .withValue(self.expiredRecord()) {
                            await strategy.isAvailable(context)
                        }
                }
            }
        }

        #expect(available == true)
    }

    @Test
    func `auto mode default reader does not bypass background startup prompt policy`() async throws {
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
                                await self.withAvailabilityKeychainDoubles {
                                    await ProviderRefreshContext.$current.withValue(.startup) {
                                        await ProviderInteractionContext.$current.withValue(.background) {
                                            await strategy.isAvailable(context)
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

    private func withAvailabilityKeychainDoubles<T>(
        operation: () async throws -> T) async rethrows -> T
    {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        return try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(
            true,
            operation: operation)
    }

    private var mcpOAuthOnlyKeychainPayload: Data {
        Data(#"{"mcpOAuth":{"plugin:test":{"accessToken":"fixture"}}}"#.utf8)
    }

    private var ordinaryOAuthKeychainPayload: Data {
        Data(#"{"claudeAiOauth":{"accessToken":"fixture"}}"#.utf8)
    }

    private func expiredCLIAvailability(
        sourceMode: ProviderSourceMode,
        interaction: ProviderInteraction,
        keychainData: Data,
        keychainAccessDisabled: Bool = false,
        promptMode: ClaudeOAuthKeychainPromptMode = .onlyOnUserAction,
        readStrategy: ClaudeOAuthKeychainReadStrategy = .securityFramework) async -> Bool
    {
        let context = self.makeContext(sourceMode: sourceMode)
        let strategy = ClaudeOAuthFetchStrategy()
        return await ClaudeOAuthFetchStrategy.$nonInteractiveCredentialRecordOverride
            .withValue(self.expiredRecord()) {
                await ClaudeOAuthFetchStrategy.$claudeCLIAvailableOverride.withValue(true) {
                    await KeychainAccessGate.withTaskOverrideForTesting(keychainAccessDisabled) {
                        await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(promptMode) {
                            await ClaudeOAuthKeychainReadStrategyPreference
                                .withTaskOverrideForTesting(readStrategy) {
                                    await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                        data: keychainData,
                                        fingerprint: nil)
                                    {
                                        await ProviderInteractionContext.$current.withValue(interaction) {
                                            await strategy.isAvailable(context)
                                        }
                                    }
                                }
                        }
                    }
                }
            }
    }
}
#endif
