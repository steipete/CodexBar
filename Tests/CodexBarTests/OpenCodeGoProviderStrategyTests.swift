import Foundation
import Testing
@testable import CodexBarCore

struct OpenCodeGoProviderStrategyTests {
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
        runtime: ProviderRuntime = .app,
        sourceMode: ProviderSourceMode = .auto,
        requiresOptionalUsageCompleteness: Bool = false,
        env: [String: String] = [:],
        settings: ProviderSettingsSnapshot? = nil,
        selectedTokenAccountID: UUID? = nil) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: runtime,
            sourceMode: sourceMode,
            includeCredits: false,
            requiresOptionalUsageCompleteness: requiresOptionalUsageCompleteness,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            selectedTokenAccountID: selectedTokenAccountID)
    }

    @Test
    func `unscoped auto source prefers local history before web fallback`() async {
        let descriptor = OpenCodeGoProviderDescriptor.makeDescriptor()
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(self.makeContext())

        #expect(strategies.map(\.id) == ["opencodego.local", "opencodego.api", "opencodego.web"])
    }

    @Test
    func `auto source tries web before local for selected token accounts`() async {
        let descriptor = OpenCodeGoProviderDescriptor.makeDescriptor()
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
            self.makeContext(selectedTokenAccountID: UUID()))

        #expect(strategies.map(\.id) == ["opencodego.web", "opencodego.local", "opencodego.api"])
    }

    @Test
    func `auto source tries web before local for manual cookies`() async {
        let descriptor = OpenCodeGoProviderDescriptor.makeDescriptor()
        let settings = ProviderSettingsSnapshot.make(opencodego: .init(
            cookieSource: .manual,
            manualCookieHeader: "auth=selected",
            workspaceID: nil))
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
            self.makeContext(settings: settings))

        #expect(strategies.map(\.id) == ["opencodego.web", "opencodego.local", "opencodego.api"])
    }

    @Test
    func `auto source tries web before local for configured workspaces`() async {
        let descriptor = OpenCodeGoProviderDescriptor.makeDescriptor()
        let settings = ProviderSettingsSnapshot.make(opencodego: .init(
            cookieSource: .auto,
            manualCookieHeader: nil,
            workspaceID: "wrk_team"))
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
            self.makeContext(settings: settings))

        #expect(strategies.map(\.id) == ["opencodego.web", "opencodego.local", "opencodego.api"])
    }

    @Test
    func `auto source tries web before local for environment workspaces`() async {
        let descriptor = OpenCodeGoProviderDescriptor.makeDescriptor()
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
            self.makeContext(env: ["CODEXBAR_OPENCODEGO_WORKSPACE_ID": "wrk_env"]))

        #expect(strategies.map(\.id) == ["opencodego.web", "opencodego.local", "opencodego.api"])
    }

    @Test
    func `auto source treats blank workspace overrides as unscoped`() async {
        let descriptor = OpenCodeGoProviderDescriptor.makeDescriptor()
        let settings = ProviderSettingsSnapshot.make(opencodego: .init(
            cookieSource: .auto,
            manualCookieHeader: nil,
            workspaceID: " \n "))
        let settingsStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
            self.makeContext(settings: settings))
        let environmentStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
            self.makeContext(env: ["CODEXBAR_OPENCODEGO_WORKSPACE_ID": " \t "]))

        #expect(settingsStrategies.map(\.id) == ["opencodego.local", "opencodego.api", "opencodego.web"])
        #expect(environmentStrategies.map(\.id) == ["opencodego.local", "opencodego.api", "opencodego.web"])
    }

    @Test
    func `web source does not include local fallback`() async {
        let descriptor = OpenCodeGoProviderDescriptor.makeDescriptor()
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(self.makeContext(sourceMode: .web))

        #expect(strategies.map(\.id) == ["opencodego.web"])
    }

    @Test
    func `api source uses only the public usage endpoint`() async {
        let descriptor = OpenCodeGoProviderDescriptor.makeDescriptor()
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(self.makeContext(sourceMode: .api))

        #expect(strategies.map(\.id) == ["opencodego.api"])
    }

    @Test
    func `local strategy falls through to web when local history is unavailable`() {
        let strategy = OpenCodeGoLocalUsageFetchStrategy()
        let context = self.makeContext()

        #expect(strategy.shouldFallback(on: OpenCodeGoLocalUsageError.notDetected, context: context))
        #expect(strategy.shouldFallback(
            on: OpenCodeGoLocalUsageError.historyUnavailable("database not found"),
            context: context))
        #expect(strategy.shouldFallback(
            on: OpenCodeGoLocalUsageError.sqliteFailed("database is locked"),
            context: context))
        #expect(!strategy.shouldFallback(on: OpenCodeGoUsageError.networkError("timeout"), context: context))
    }

    @Test
    func `web strategy falls through only for auth setup failures in auto mode`() {
        let strategy = OpenCodeGoUsageFetchStrategy()
        let autoContext = self.makeContext()
        let webContext = self.makeContext(sourceMode: .web)

        #expect(strategy.shouldFallback(on: OpenCodeGoSettingsError.missingCookie, context: autoContext))
        #expect(strategy.shouldFallback(on: OpenCodeGoSettingsError.invalidCookie, context: autoContext))
        #expect(strategy.shouldFallback(on: OpenCodeGoUsageError.invalidCredentials, context: autoContext))
        #expect(!strategy.shouldFallback(on: OpenCodeGoUsageError.networkError("timeout"), context: autoContext))
        #expect(!strategy.shouldFallback(on: OpenCodeGoSettingsError.missingCookie, context: webContext))
    }

    @Test
    func `web strategy surfaces authentication failures for selected token accounts`() {
        let strategy = OpenCodeGoUsageFetchStrategy()
        let settings = ProviderSettingsSnapshot.make(opencodego: .init(
            cookieSource: .manual,
            manualCookieHeader: "auth=selected",
            workspaceID: nil))
        let manualContext = self.makeContext(settings: settings)
        let selectedAccountContext = self.makeContext(selectedTokenAccountID: UUID())

        #expect(!strategy.shouldFallback(on: OpenCodeGoSettingsError.invalidCookie, context: manualContext))
        #expect(!strategy.shouldFallback(on: OpenCodeGoUsageError.invalidCredentials, context: manualContext))
        #expect(!strategy.shouldFallback(on: OpenCodeGoSettingsError.missingCookie, context: selectedAccountContext))
        #expect(!strategy.shouldFallback(
            on: OpenCodeGoUsageError.invalidCredentials,
            context: selectedAccountContext))
    }

    @Test
    func `web strategy waits for zen balance only on usage completeness reads`() {
        #expect(!OpenCodeGoUsageFetchStrategy.shouldWaitForZenBalance(
            context: self.makeContext(runtime: .app)))
        #expect(!OpenCodeGoUsageFetchStrategy.shouldWaitForZenBalance(
            context: self.makeContext(runtime: .cli)))
        #expect(OpenCodeGoUsageFetchStrategy.shouldWaitForZenBalance(
            context: self.makeContext(runtime: .cli, requiresOptionalUsageCompleteness: true)))
    }
}
