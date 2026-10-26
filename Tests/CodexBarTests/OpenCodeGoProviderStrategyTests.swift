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

        #expect(strategies.map(\.id) == ["opencodego.local", "opencodego.web", "opencodego.api"])
    }

    @Test
    func `configured API key keeps precedence when local history is unavailable`() async {
        let strategies = await OpenCodeGoProviderDescriptor.makeDescriptor().fetchPlan.pipeline
            .resolveStrategies(self.makeContext(env: ["OPENCODE_API_KEY": "synthetic-key"]))

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

        #expect(settingsStrategies.map(\.id) == ["opencodego.local", "opencodego.web", "opencodego.api"])
        #expect(environmentStrategies.map(\.id) == ["opencodego.local", "opencodego.web", "opencodego.api"])
    }

    @Test
    func `blank workspace settings preserve an explicit environment workspace`() async {
        let settings = ProviderSettingsSnapshot.make(opencodego: .init(
            cookieSource: .auto,
            manualCookieHeader: nil,
            workspaceID: " \n "))
        let context = self.makeContext(
            env: ["CODEXBAR_OPENCODEGO_WORKSPACE_ID": "  wrk_selected  "],
            settings: settings)
        let strategies = await OpenCodeGoProviderDescriptor.makeDescriptor().fetchPlan.pipeline
            .resolveStrategies(context)

        #expect(OpenCodeGoSettingsReader.workspaceID(context: context) == "wrk_selected")
        #expect(strategies.map(\.id) == ["opencodego.web", "opencodego.local", "opencodego.api"])
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
        let strategy = OpenCodeGoLocalUsageFetchStrategy(cliCredentialLoader: { _ in nil })
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
    func `API source reuses the CLI login without local history`() async throws {
        let strategy = OpenCodeGoAPIUsageFetchStrategy(
            cliCredentialLoader: { _ in "cli-access" },
            usageFetcher: { _, token in
                #expect(token == "cli-access")
                return try OpenCodeGoUsageFetcher.parseAPIUsage(
                    text: #"{"usage":{"rolling":{"percent":100},"weekly":{"percent":80},"monthly":{"percent":90}}}"#,
                    now: Date(timeIntervalSince1970: 1_800_000_000))
            })

        let result = try await strategy.fetch(self.makeContext(sourceMode: .api))

        #expect(result.sourceLabel == "cli")
        #expect(result.usage.primary?.usedPercent == 100)
        #expect(result.usage.secondary?.usedPercent == 80)
        #expect(result.usage.tertiary?.usedPercent == 90)
        #expect(result.usage.dataConfidence != .estimated)
    }

    @Test(arguments: [false, true])
    func `explicit API keys never borrow the CLI account`(rejected: Bool) async throws {
        let strategy = OpenCodeGoAPIUsageFetchStrategy(
            cliCredentialLoader: { _ in
                Issue.record("An explicit API key must not read ambient CLI credentials")
                return "another-account"
            },
            usageFetcher: { _, token in
                #expect(token == "selected-key")
                if rejected { throw OpenCodeGoUsageError.invalidCredentials }
                return try OpenCodeGoUsageFetcher.parseAPIUsage(
                    text: #"{"usage":{"rolling":{"percent":25}}}"#,
                    now: Date(timeIntervalSince1970: 1_800_000_000))
            })
        let context = self.makeContext(sourceMode: .api, env: ["OPENCODE_API_KEY": "selected-key"])

        if rejected {
            await #expect(throws: OpenCodeGoUsageError.self) { try await strategy.fetch(context) }
        } else {
            let result = try await strategy.fetch(context)
            #expect(result.sourceLabel == "api")
            #expect(result.usage.primary?.usedPercent == 25)
        }
    }

    @Test(arguments: ["account", "manual-cookie", "workspace", "environment-workspace", "web"])
    func `explicit scopes never borrow the ambient CLI login`(scope: String) async {
        let settings = ProviderSettingsSnapshot.make(opencodego: .init(
            cookieSource: scope == "manual-cookie" ? .manual : .auto,
            manualCookieHeader: scope == "manual-cookie" ? "auth=selected" : nil,
            workspaceID: scope == "workspace" ? "wrk_selected" : nil))
        let strategy = OpenCodeGoAPIUsageFetchStrategy(
            cliCredentialLoader: { _ in
                Issue.record("A scoped request must not read another CLI account")
                return "another-account"
            },
            usageFetcher: { _, _ in
                Issue.record("A scoped request without an API key must not send another account's token")
                throw OpenCodeGoUsageError.invalidCredentials
            })
        let context = self.makeContext(
            sourceMode: scope == "web" ? .web : .api,
            env: scope == "environment-workspace" ? ["CODEXBAR_OPENCODEGO_WORKSPACE_ID": "wrk_selected"] : [:],
            settings: settings,
            selectedTokenAccountID: scope == "account" ? UUID() : nil)

        await #expect(throws: OpenCodeGoSettingsError.self) { try await strategy.fetch(context) }
    }

    @Test
    func `API source surfaces an expired CLI login`() async {
        let strategy = OpenCodeGoAPIUsageFetchStrategy(
            cliCredentialLoader: { _ in throw OpenCodeGoUsageError.invalidCredentials },
            usageFetcher: { _, _ in
                Issue.record("An expired login must not reach the usage endpoint")
                throw OpenCodeGoUsageError.invalidCredentials
            })

        await #expect(throws: OpenCodeGoUsageError.self) {
            try await strategy.fetch(self.makeContext(sourceMode: .api))
        }
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
