import Foundation
import Testing
@testable import CodexBarCore

@Suite(CodexCredentialFixtures())
struct CodexOAuthManagedWorkspaceRecoveryTests {
    @Test
    func `automatic mode exposes scoped native refresh without unscoped CLI usage fallback`() async {
        let context = self.makeContext(sourceMode: .auto)
        let strategies = await CodexProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)

        #expect(strategies.map(\.id) == ["codex.pat", "codex.oauth", "codex.oauth-native-refresh-cli"])
    }

    @Test
    func `native refresh recovery is available when managed workspace scope is selected`() async throws {
        let home = CodexCredentialFixtures.root
            .appendingPathComponent("codexbar-native-refresh-managed-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try CodexOAuthCredentialsStore.save(
            CodexOAuthCredentials(
                accessToken: "access-token",
                refreshToken: "refresh-token",
                idToken: nil,
                accountId: "auth-account",
                lastRefresh: Date(timeIntervalSinceNow: -(9 * 24 * 60 * 60))),
            env: ["CODEX_HOME": home.path])

        let context = self.makeContext(sourceMode: .oauth, env: ["CODEX_HOME": home.path])

        let isAvailable = await CodexOAuthNativeRefreshCLIStrategy(binaryResolver: { _ in "/usr/bin/codex" })
            .isAvailable(context)
        #expect(isAvailable)
    }

    @Test
    func `native refresh reloads scoped credentials before fetching the selected workspace`() async throws {
        let home = CodexCredentialFixtures.root
            .appendingPathComponent("codexbar-native-refresh-selected-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try CodexOAuthCredentialsStore.save(
            CodexOAuthCredentials(
                accessToken: "stale-access-token",
                refreshToken: "stale-refresh-token",
                idToken: nil,
                accountId: "auth-account",
                lastRefresh: Date(timeIntervalSinceNow: -(9 * 24 * 60 * 60))),
            env: ["CODEX_HOME": home.path])

        let context = self.makeContext(
            sourceMode: .oauth,
            env: ["CODEX_HOME": home.path],
            runtime: .cli)
        let strategy = CodexOAuthNativeRefreshCLIStrategy(
            binaryResolver: { _ in "/usr/bin/codex" },
            credentialRefresher: { context in
                try CodexOAuthCredentialsStore.save(
                    CodexOAuthCredentials(
                        accessToken: "refreshed-access-token",
                        refreshToken: "rotated-refresh-token",
                        idToken: nil,
                        accountId: "auth-account",
                        lastRefresh: Date()),
                    env: context.env)
            })
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?.path == "/backend-api/wham/usage")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-access-token")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "workspace-team")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(Self.usageBody.utf8), response)
        }

        let result = try await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            try await strategy.fetch(context)
        }

        #expect(result.strategyID == "codex.oauth")
        #expect(result.usage.primary?.usedPercent == 22)
        #expect(await transport.requests().count == 1)
    }

    private func makeContext(
        sourceMode: ProviderSourceMode,
        env: [String: String] = [:],
        runtime: ProviderRuntime = .app) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let settings = ProviderSettingsSnapshot.make(codex: CodexProviderSettings(
            usageDataSource: sourceMode == .auto ? .auto : .oauth,
            cookieSource: .off,
            manualCookieHeader: nil,
            managedWorkspaceAccountID: "workspace-team"))
        return ProviderFetchContext(
            runtime: runtime,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private static let usageBody = #"""
    {
      "plan_type":"pro",
      "rate_limit":{
        "primary_window":{"used_percent":22,"reset_at":4102444800,"limit_window_seconds":18000},
        "secondary_window":{"used_percent":43,"reset_at":4102444800,"limit_window_seconds":604800}
      }
    }
    """#
}
