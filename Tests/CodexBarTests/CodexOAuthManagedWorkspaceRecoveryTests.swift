import Foundation
import Testing
@testable import CodexBarCore

struct CodexOAuthManagedWorkspaceRecoveryTests {
    @Test
    func `automatic mode does not expose unscoped CLI fallback for a managed workspace`() async {
        let context = self.makeContext(sourceMode: .auto)
        let strategies = await CodexProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)

        #expect(strategies.map(\.id) == ["codex.pat", "codex.oauth"])
    }

    @Test
    func `native refresh recovery is unavailable when managed workspace scope is selected`() async throws {
        let home = FileManager.default.temporaryDirectory
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
        #expect(!isAvailable)
    }

    private func makeContext(
        sourceMode: ProviderSourceMode,
        env: [String: String] = [:]) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let settings = ProviderSettingsSnapshot.make(codex: CodexProviderSettings(
            usageDataSource: sourceMode == .auto ? .auto : .oauth,
            cookieSource: .off,
            manualCookieHeader: nil,
            managedWorkspaceAccountID: "workspace-team"))
        return ProviderFetchContext(
            runtime: .app,
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
}
