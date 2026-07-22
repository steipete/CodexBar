import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct ClaudeOAuthUpgradeCompatibilityTests {
    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var oauthTokens: [String] = []
        private var webCalls: [String] = []
        private var foreignKeychainReads: Int = 0

        func recordOAuthToken(_ token: String) {
            self.lock.withLock { self.oauthTokens.append(token) }
        }

        func recordWebCall(_ call: String) {
            self.lock.withLock { self.webCalls.append(call) }
        }

        func recordForeignKeychainRead() {
            self.lock.withLock { self.foreignKeychainReads += 1 }
        }

        var recordedOAuthTokens: [String] {
            self.lock.withLock { self.oauthTokens }
        }

        var recordedWebCalls: [String] {
            self.lock.withLock { self.webCalls }
        }

        var recordedForeignKeychainReads: Int {
            self.lock.withLock { self.foreignKeychainReads }
        }
    }

    private struct UnexpectedClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            Issue.record("Persisted OAuth must not invoke the Claude CLI fetcher")
            throw ClaudeUsageError.parseFailed("unexpected CLI fetch")
        }

        func debugRawProbe(model _: String) async -> String {
            Issue.record("Persisted OAuth must not invoke the Claude CLI debug probe")
            return "unexpected CLI debug probe"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    @Test
    func `persisted OAuth uses environment credentials only`() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try Self.makeFakeClaudeCLI(in: root)
        let missingCredentials = root.appendingPathComponent("missing-credentials.json")
        let expectedToken = "environment-oauth-token"
        let environment = [
            ClaudeOAuthCredentialsStore.environmentTokenKey: expectedToken,
            ClaudeOAuthCredentialsStore.environmentScopesKey: "user:profile",
            "CLAUDE_CLI_PATH": cli.executable.path,
        ]

        try await self.verifyPersistedOAuthFetch(
            suite: "ClaudeOAuthUpgradeCompatibilityTests-environment",
            environment: environment,
            credentialsURLOverride: missingCredentials,
            expectedToken: expectedToken,
            cliInvocationLog: cli.invocationLog)
    }

    @Test
    func `persisted OAuth uses profile file credentials only`() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try Self.makeFakeClaudeCLI(in: root)
        let expectedToken = "profile-file-oauth-token"
        let credentialsURL = root.appendingPathComponent(".credentials.json")
        try Self.makeCredentialsData(accessToken: expectedToken).write(to: credentialsURL)
        let environment = [
            ClaudeConfigPaths.configDirectoryEnvironmentKey: root.path,
            "CLAUDE_CLI_PATH": cli.executable.path,
        ]

        try await self.verifyPersistedOAuthFetch(
            suite: "ClaudeOAuthUpgradeCompatibilityTests-file",
            environment: environment,
            credentialsURLOverride: nil,
            expectedToken: expectedToken,
            cliInvocationLog: cli.invocationLog)
    }

    @Test
    func `persisted OAuth with only foreign Keychain fails closed`() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try Self.makeFakeClaudeCLI(in: root)
        let missingCredentials = root.appendingPathComponent("missing-credentials.json")
        let context = try self.makePersistedOAuthContext(
            suite: "ClaudeOAuthUpgradeCompatibilityTests-foreign-only",
            environment: ["CLAUDE_CLI_PATH": cli.executable.path])
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .claude)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)

        #expect(context.sourceMode == .oauth)
        #expect(context.settings?.claude?.usageDataSource == .oauth)
        #expect(strategies.map(\.id) == ["claude.oauth"])
        guard strategies.map(\.id) == ["claude.oauth"] else { return }

        let calls = CallLog()
        let outcome = try await Self.withIsolatedCredentialState(credentialsURLOverride: missingCredentials) {
            try await Self.withForeignKeychainTripwires(calls: calls) {
                await Self.withWebTripwires(calls: calls) {
                    await descriptor.fetchOutcome(context: context)
                }
            }
        }

        #expect(outcome.attempts.map(\.strategyID) == ["claude.oauth"])
        if case let .success(result) = outcome.result {
            Issue.record("Foreign Claude Keychain fixture unexpectedly produced \(result.strategyID)")
        }
        #expect(calls.recordedOAuthTokens.isEmpty)
        #expect(calls.recordedWebCalls.isEmpty)
        #expect(calls.recordedForeignKeychainReads == 0)
        #expect(Self.cliInvocations(at: cli.invocationLog).isEmpty)
    }

    private func verifyPersistedOAuthFetch(
        suite: String,
        environment: [String: String],
        credentialsURLOverride: URL?,
        expectedToken: String,
        cliInvocationLog: URL) async throws
    {
        #expect(ClaudeOAuthCredentialsStore.directClaudeCodeKeychainAccessAllowedForTesting == false)

        let context = try self.makePersistedOAuthContext(suite: suite, environment: environment)
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .claude)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)

        #expect(context.sourceMode == .oauth)
        #expect(context.settings?.claude?.usageDataSource == .oauth)
        #expect(strategies.map(\.id) == ["claude.oauth"])
        guard strategies.map(\.id) == ["claude.oauth"] else { return }

        let calls = CallLog()
        let response = try Self.makeOAuthUsageResponse()
        let fetchOAuthUsage: @Sendable (String, Bool) async throws -> OAuthUsageResponse = { token, _ in
            calls.recordOAuthToken(token)
            return response
        }
        let outcome = try await Self.withIsolatedCredentialState(
            credentialsURLOverride: credentialsURLOverride)
        {
            try await Self.withForeignKeychainTripwires(calls: calls) {
                await Self.withWebTripwires(calls: calls) {
                    await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchOAuthUsage) {
                        await descriptor.fetchOutcome(context: context)
                    }
                }
            }
        }

        #expect(outcome.attempts.map(\.strategyID) == ["claude.oauth"])
        #expect(outcome.attempts.map(\.wasAvailable) == [true])
        switch outcome.result {
        case let .success(result):
            #expect(result.strategyID == "claude.oauth")
            #expect(result.sourceLabel == "oauth")
            #expect(result.usage.primary?.usedPercent == 7)
            #expect(result.usage.secondary?.usedPercent == 21)
        case let .failure(error):
            Issue.record("Expected persisted OAuth fetch to succeed, got \(error)")
        }
        #expect(calls.recordedOAuthTokens == [expectedToken])
        #expect(calls.recordedWebCalls.isEmpty)
        #expect(calls.recordedForeignKeychainReads == 0)
        #expect(Self.cliInvocations(at: cliInvocationLog).isEmpty)
    }

    private func makePersistedOAuthContext(
        suite: String,
        environment: [String: String]) throws -> ProviderFetchContext
    {
        let config = CodexBarConfig(providers: [
            ProviderConfig(
                id: .claude,
                source: .oauth,
                cookieHeader: "sessionKey=synthetic-web-session",
                cookieSource: .manual),
        ])
        let settings = testSettingsStore(suiteName: suite, config: config)

        #expect(settings.providerConfig(for: .claude)?.source == .oauth)
        #expect(settings.claudeUsageDataSource == .oauth)
        #expect(settings.claudeSettingsSnapshot(tokenOverride: nil).usageDataSource == .oauth)

        let browserDetection = BrowserDetection(cacheTTL: 0)
        let specs = ProviderRegistry.shared.specs(
            settings: settings,
            metadata: ProviderRegistry.shared.metadata,
            codexFetcher: UsageFetcher(environment: environment),
            claudeFetcher: UnexpectedClaudeFetcher(),
            browserDetection: browserDetection,
            environmentBase: environment)
        return try #require(specs[.claude]).makeFetchContext()
    }

    private nonisolated static func withIsolatedCredentialState<T: Sendable>(
        credentialsURLOverride: URL?,
        operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        let service = "com.steipete.codexbar.oauth-upgrade-tests.\(UUID().uuidString)"
        return try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            return try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(
                        credentialsURLOverride)
                    {
                        try await operation()
                    }
                }
            }
        }
    }

    private nonisolated static func withForeignKeychainTripwires<T: Sendable>(
        calls: CallLog,
        operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        let foreignCredentials = Self.makeCredentialsData(accessToken: "foreign-keychain-token")
        return try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
            try await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                data: foreignCredentials,
                fingerprint: .init(modifiedAt: 1, createdAt: 1, persistentRefHash: "foreign-ref"))
            {
                try await ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                    .dynamic { _ in
                        calls.recordForeignKeychainRead()
                        return foreignCredentials
                    }) {
                        try await ClaudeOAuthCredentialsStore.withInteractiveClaudeKeychainReadOverridesForTesting(
                            read: {
                                calls.recordForeignKeychainRead()
                                return foreignCredentials
                            },
                            operation: {
                                #expect(
                                    ClaudeOAuthCredentialsStore
                                        .directClaudeCodeKeychainAccessAllowedForTesting == false)
                                return try await operation()
                            })
                    }
            }
        }
    }

    private nonisolated static func withWebTripwires<T: Sendable>(
        calls: CallLog,
        operation: @escaping @Sendable () async throws -> T) async rethrows -> T
    {
        let availability: @Sendable (ProviderFetchContext, BrowserDetection) -> Bool = { _, _ in
            calls.recordWebCall("availability")
            return true
        }
        let loader: ClaudeWebFetchStrategy.UsageLoader = { _ in
            calls.recordWebCall("fetch")
            throw ClaudeUsageError.parseFailed("unexpected web fetch")
        }
        return try await ClaudeWebFetchStrategy.$availabilityProbeOverrideForTesting.withValue(availability) {
            try await ClaudeWebFetchStrategy.$usageLoaderOverrideForTesting.withValue(loader) {
                try await operation()
            }
        }
    }

    private nonisolated static func makeCredentialsData(accessToken: String) -> Data {
        let expiresAt = Int(Date(timeIntervalSinceNow: 3600).timeIntervalSince1970 * 1000)
        return Data("""
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "expiresAt": \(expiresAt),
            "scopes": ["user:profile"]
          }
        }
        """.utf8)
    }

    private static func makeOAuthUsageResponse() throws -> OAuthUsageResponse {
        try ClaudeOAuthUsageFetcher._decodeUsageResponseForTesting(Data("""
        {
          "five_hour": { "utilization": 7, "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day": { "utilization": 21, "resets_at": "2025-12-29T23:00:00.000Z" }
        }
        """.utf8))
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-oauth-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeFakeClaudeCLI(in directory: URL) throws -> (executable: URL, invocationLog: URL) {
        let executable = directory.appendingPathComponent("claude")
        let invocationLog = directory.appendingPathComponent("claude-invocations.log")
        try Data("""
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(invocationLog.path)"
        exit 88
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (executable, invocationLog)
    }

    private static func cliInvocations(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
