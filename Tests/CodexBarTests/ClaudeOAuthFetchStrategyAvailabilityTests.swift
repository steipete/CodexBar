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
        env: [String: String] = [:],
        settings: ProviderSettingsSnapshot? = nil,
        includeOptionalUsage: Bool = true,
        webTimeout: TimeInterval = 1) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            includeOptionalUsage: includeOptionalUsage,
            webTimeout: webTimeout,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
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
    func `O auth strategy enriches usage with web balance when optional usage is enabled`() async throws {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .manual,
            manualCookieHeader: "sessionKey=sk-ant-session-token"))
        let context = self.makeContext(sourceMode: .auto, settings: settings)
        let credentials = ClaudeOAuthCredentials(
            accessToken: "oauth-token",
            refreshToken: nil,
            expiresAt: Date(timeIntervalSinceNow: 3600),
            scopes: ["user:profile"],
            rateLimitTier: "claude_pro")
        let usageResponse = try ClaudeOAuthUsageFetcher._decodeUsageResponseForTesting(Data("""
        {
          "five_hour": { "utilization": 7 },
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 2000,
            "used_credits": 500,
            "currency": "USD"
          }
        }
        """.utf8))
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let body: String
            let statusCode: Int
            switch url.path {
            case "/api/organizations":
                body = #"[{"uuid":"org-123","name":"Test Org","capabilities":["chat"]}]"#
                statusCode = 200
            case "/api/organizations/org-123/usage":
                body = #"{"five_hour":{"utilization":44}}"#
                statusCode = 200
            case "/api/organizations/org-123/prepaid/credits":
                body = #"{"amount":10000,"currency":"USD"}"#
                statusCode = 200
            case "/api/account":
                body = """
                {
                  "email_address": "user@example.com",
                  "memberships": [{"organization": {"uuid": "org-123"}}]
                }
                """
                statusCode = 200
            default:
                body = "{}"
                statusCode = 404
            }
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]))
            return (Data(body.utf8), response)
        }
        let loadCredentials: @Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials = { _, _, _ in credentials }
        let fetchUsage: @Sendable (String, Bool) async throws -> OAuthUsageResponse = { _, _ in usageResponse }
        let fetchProfile: @Sendable (String) async throws -> OAuthProfileResponse = { _ in
            OAuthProfileResponse(emailAddress: "user@example.com", organizationUuid: "org-123")
        }

        let result = try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
            try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(loadCredentials) {
                try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchUsage) {
                    try await ClaudeUsageFetcher.$fetchOAuthProfileOverride.withValue(fetchProfile) {
                        try await ClaudeOAuthFetchStrategy().fetch(context)
                    }
                }
            }
        }

        #expect(result.usage.primary?.usedPercent == 7)
        #expect(result.usage.providerCost?.used == 5)
        #expect(result.usage.providerCost?.limit == 20)
        #expect(result.usage.providerCost?.balance == 100)
    }

    @Test
    func `auto without cached web session publishes O auth usage without browser discovery`() async throws {
        try await self.withIsolatedCookieCache {
            let settings = ProviderSettingsSnapshot.make(claude: .init(
                usageDataSource: .auto,
                webExtrasEnabled: false,
                cookieSource: .auto,
                manualCookieHeader: nil))
            let context = self.makeContext(sourceMode: .auto, settings: settings)
            let credentials = ClaudeOAuthCredentials(
                accessToken: "oauth-token",
                refreshToken: nil,
                expiresAt: Date(timeIntervalSinceNow: 3600),
                scopes: ["user:profile"],
                rateLimitTier: "claude_pro")
            let usageResponse = try ClaudeOAuthUsageFetcher._decodeUsageResponseForTesting(Data("""
            {"five_hour":{"utilization":7}}
            """.utf8))
            let importedSession = ClaudeWebAPIFetcher.SessionKeyInfo(
                key: "sk-ant-browser-session",
                sourceLabel: "Browser",
                cookieCount: 1)
            let transport = ProviderHTTPTransportHandler { request in
                let url = request.url?.absoluteString ?? "nil"
                Issue.record("Unexpected Claude browser-cookie discovery request: \(url)")
                throw URLError(.badServerResponse)
            }
            let loadCredentials: @Sendable (
                [String: String],
                Bool,
                Bool) async throws -> ClaudeOAuthCredentials = { _, _, _ in credentials }
            let fetchUsage: @Sendable (String, Bool) async throws -> OAuthUsageResponse = { _, _ in usageResponse }
            let fetchProfile: @Sendable (String) async throws -> OAuthProfileResponse = { _ in
                OAuthProfileResponse(emailAddress: "user@example.com", organizationUuid: "org-123")
            }

            let result = try await ClaudeWebSessionKeyImport.$overrideForTesting.withValue(importedSession) {
                try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
                    try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(loadCredentials) {
                        try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchUsage) {
                            try await ClaudeUsageFetcher.$fetchOAuthProfileOverride.withValue(fetchProfile) {
                                try await ClaudeOAuthFetchStrategy().fetch(context)
                            }
                        }
                    }
                }
            }

            #expect(result.usage.primary?.usedPercent == 7)
            #expect(result.usage.providerCost == nil)
        }
    }

    @Test
    func `blank manual cookie does not fall back to browser enrichment`() async throws {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .oauth,
            webExtrasEnabled: true,
            cookieSource: .manual,
            manualCookieHeader: "   "))
        let context = self.makeContext(sourceMode: .oauth, settings: settings)
        let credentials = ClaudeOAuthCredentials(
            accessToken: "oauth-token",
            refreshToken: nil,
            expiresAt: Date(timeIntervalSinceNow: 3600),
            scopes: ["user:profile"],
            rateLimitTier: "claude_pro")
        let usageResponse = try ClaudeOAuthUsageFetcher._decodeUsageResponseForTesting(Data("""
        {
          "five_hour": { "utilization": 7 }
        }
        """.utf8))
        let transport = ProviderHTTPTransportHandler { request in
            Issue.record("Unexpected Claude web request: \(request.url?.absoluteString ?? "nil")")
            throw URLError(.badServerResponse)
        }
        let loadCredentials: @Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials = { _, _, _ in credentials }
        let fetchUsage: @Sendable (String, Bool) async throws -> OAuthUsageResponse = { _, _ in usageResponse }

        let result = try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
            try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(loadCredentials) {
                try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchUsage) {
                    try await ClaudeOAuthFetchStrategy().fetch(context)
                }
            }
        }

        #expect(result.usage.primary?.usedPercent == 7)
        #expect(result.usage.providerCost == nil)
    }

    @Test
    func `O auth web enrichment timeout preserves completed usage`() async throws {
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .oauth,
            webExtrasEnabled: false,
            cookieSource: .manual,
            manualCookieHeader: "sessionKey=sk-ant-session-token"))
        let context = self.makeContext(
            sourceMode: .oauth,
            settings: settings,
            webTimeout: 0.02)
        let credentials = ClaudeOAuthCredentials(
            accessToken: "oauth-token",
            refreshToken: nil,
            expiresAt: Date(timeIntervalSinceNow: 3600),
            scopes: ["user:profile"],
            rateLimitTier: "claude_pro")
        let usageResponse = try ClaudeOAuthUsageFetcher._decodeUsageResponseForTesting(Data("""
        {"five_hour":{"utilization":7}}
        """.utf8))
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            if url.path == "/api/organizations" {
                try await Task.sleep(for: .seconds(10))
                throw CancellationError()
            }
            throw URLError(.badServerResponse)
        }
        let loadCredentials: @Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials = { _, _, _ in credentials }
        let fetchUsage: @Sendable (String, Bool) async throws -> OAuthUsageResponse = { _, _ in usageResponse }
        let fetchProfile: @Sendable (String) async throws -> OAuthProfileResponse = { _ in
            OAuthProfileResponse(emailAddress: "user@example.com", organizationUuid: "org-123")
        }

        let result = try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
            try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(loadCredentials) {
                try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchUsage) {
                    try await ClaudeUsageFetcher.$fetchOAuthProfileOverride.withValue(fetchProfile) {
                        try await ClaudeOAuthFetchStrategy().fetch(context)
                    }
                }
            }
        }

        #expect(result.usage.primary?.usedPercent == 7)
        #expect(result.usage.providerCost?.balance == nil)
    }

    @Test
    func `auto CLI fallback enriches usage with matching web balance`() async throws {
        let cliPath = try Self.makeExecutableClaudeStub()
        defer { try? FileManager.default.removeItem(atPath: cliPath) }
        let settings = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .manual,
            manualCookieHeader: "sessionKey=sk-ant-session-token"))
        let context = self.makeContext(
            sourceMode: .auto,
            env: ["CLAUDE_CLI_PATH": cliPath],
            settings: settings)
        let unavailableOAuthRecord = ClaudeOAuthCredentialRecord(
            credentials: ClaudeOAuthCredentials(
                accessToken: "oauth-token-without-profile-scope",
                refreshToken: nil,
                expiresAt: Date(timeIntervalSinceNow: 3600),
                scopes: ["user:inference"],
                rateLimitTier: nil),
            owner: .claudeCLI,
            source: .environment)
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let body: String
            let statusCode: Int
            switch url.path {
            case "/api/organizations":
                body = #"[{"uuid":"org-123","name":"Test Org","capabilities":["chat"]}]"#
                statusCode = 200
            case "/api/organizations/org-123/usage":
                body = #"{"five_hour":{"utilization":44}}"#
                statusCode = 200
            case "/api/organizations/org-123/prepaid/credits":
                body = #"{"amount":10000,"currency":"USD"}"#
                statusCode = 200
            case "/api/account":
                body = """
                {
                  "email_address": "user@example.com",
                  "memberships": [{"organization": {"uuid": "org-123"}}]
                }
                """
                statusCode = 200
            default:
                body = "{}"
                statusCode = 404
            }
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]))
            return (Data(body.utf8), response)
        }
        let cliFetch: @Sendable (String, TimeInterval, Bool) async throws -> ClaudeStatusSnapshot = { _, _, _ in
            ClaudeStatusSnapshot(
                sessionPercentLeft: 93,
                weeklyPercentLeft: nil,
                opusPercentLeft: nil,
                accountEmail: "user@example.com",
                accountOrganization: "Test Org",
                loginMethod: "Pro",
                primaryResetDescription: nil,
                secondaryResetDescription: nil,
                opusResetDescription: nil,
                rawText: "stub")
        }

        func fetchResult(context: ProviderFetchContext) async throws -> ProviderFetchResult {
            let outcome = await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
                await ClaudeOAuthFetchStrategy.$nonInteractiveCredentialRecordOverride.withValue(
                    unavailableOAuthRecord)
                {
                    await ClaudeOAuthFetchStrategy.$claudeCLIAvailableOverride.withValue(true) {
                        await ClaudeOAuthKeychainAccessGate.withShouldAllowPromptOverrideForTesting(false) {
                            await ClaudeStatusProbe.$fetchOverride.withValue(cliFetch) {
                                await ProviderInteractionContext.$current.withValue(.userInitiated) {
                                    await ClaudeProviderDescriptor.makeDescriptor().fetchPlan.fetchOutcome(
                                        context: context,
                                        provider: .claude)
                                }
                            }
                        }
                    }
                }
            }
            return try outcome.result.get()
        }

        let result = try await fetchResult(context: context)

        #expect(result.strategyID == "claude.cli")
        #expect(result.usage.primary?.usedPercent == 7)
        #expect(result.usage.providerCost?.balance == 100)

        let hiddenResult = try await fetchResult(context: self.makeContext(
            sourceMode: .auto,
            env: ["CLAUDE_CLI_PATH": cliPath],
            settings: settings,
            includeOptionalUsage: false))
        #expect(hiddenResult.strategyID == "claude.cli")
        #expect(hiddenResult.usage.primary?.usedPercent == 7)
        #expect(hiddenResult.usage.providerCost == nil)
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
    func `auto mode selected profile file ignores unrelated MCP-only keychain`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profile = root.appendingPathComponent("selected-profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = ["CLAUDE_CONFIG_DIR": profile.path]
        let expiresAt = Int(Date(timeIntervalSinceNow: -60).timeIntervalSince1970 * 1000)
        let data = Data(#"""
        {
          "claudeAiOauth": {
            "accessToken": "selected-expired",
            "refreshToken": "selected-refresh",
            "expiresAt": \#(expiresAt),
            "scopes": ["user:profile"]
          }
        }
        """#.utf8)
        try data.write(to: ClaudeConfigPaths.credentialsURL(environment: environment))

        let available = await ClaudeOAuthCredentialsStore.withEnvironmentCredentialsURLForTesting {
            await self.expiredCLIAvailability(
                sourceMode: .auto,
                interaction: .background,
                keychainData: self.mcpOAuthOnlyKeychainPayload,
                promptMode: .always,
                env: environment)
        }

        #expect(available)
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

    private static func makeExecutableClaudeStub() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-extra-credit-\(UUID().uuidString)")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func withIsolatedCookieCache<T>(_ operation: () async throws -> T) async rethrows -> T {
        let legacyBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-oauth-enrichment-\(UUID().uuidString)", isDirectory: true)
        let service = "claude-oauth-enrichment-\(UUID().uuidString)"
        return try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            try await CookieHeaderCache.withLegacyBaseURLOverrideForTesting(legacyBase) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }
                CookieHeaderCache.resetDisplayCacheForTesting()
                defer { CookieHeaderCache.resetDisplayCacheForTesting() }
                return try await operation()
            }
        }
    }

    private func expiredCLIAvailability(
        sourceMode: ProviderSourceMode,
        interaction: ProviderInteraction,
        keychainData: Data,
        keychainAccessDisabled: Bool = false,
        promptMode: ClaudeOAuthKeychainPromptMode = .onlyOnUserAction,
        readStrategy: ClaudeOAuthKeychainReadStrategy = .securityFramework,
        env: [String: String] = [:]) async -> Bool
    {
        let context = self.makeContext(sourceMode: sourceMode, env: env)
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
