import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized, ClaudeOAuthDefaultsFixtures(), ProviderTransportRegressionFixtures())
@MainActor
struct ClaudeOAuthTransportIdentityTests {
    @Test(arguments: ProviderTransportRegressionSupport.codes)
    func `explicit OAuth producer retains localized transport identity`(code: URLError.Code) async {
        let (error, transport) = await Self.failure(underlying: ProviderTransportRegressionSupport.urlError(code))
        #expect(await transport.requests().count == 1)
        ProviderTransportRegressionSupport.expectPolicy(error, code: code)
        if code != .cancelled {
            #expect(error.localizedDescription == "Claude OAuth network error: Verbindung fehlgeschlagen")
            #expect((error as NSError).userInfo["fixture-marker"] as? String == "preserved")
        }
        #expect(!ClaudeOAuthFetchStrategy().shouldFallback(on: error, context: Self.context()))
    }

    @Test
    func `explicit OAuth task cancellation stays typed and terminal`() async {
        let (error, _) = await Self.failure(underlying: CancellationError())
        #expect(error is CancellationError)
        ProviderTransportRegressionSupport.expectPolicy(error, code: .cancelled)
        #expect(!ClaudeOAuthFetchStrategy().shouldFallback(on: error, context: Self.context()))
    }

    @Test(arguments: [URLError.Code.badURL, .secureConnectionFailed])
    func `explicit OAuth does not broaden the URL retention allowlist`(code: URLError.Code) async {
        let (error, _) = await Self.failure(underlying: ProviderTransportRegressionSupport.urlError(code))
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
        #expect(!UsageStore.isStartupConnectivityRetryableError(error))
        #expect(UsageStore.refreshFailureHookStatus(error) == "network_error")
    }

    @Test(arguments: [true, false])
    func `two explicit OAuth outages preserve only prior quota measurements`(hasPriorData: Bool) async throws {
        let (error, _) = await Self.failure(underlying: ProviderTransportRegressionSupport.urlError())
        try await ProviderTransportRegressionSupport.withStore(
            provider: .claude,
            hasPriorData: hasPriorData)
        { store, prior in
            #expect(store.settings.claudeUsageDataSource == .oauth)
            var fetches = 0
            store._test_providerFetchOutcomeOverride = { _ in
                fetches += 1
                return ProviderFetchOutcome(result: .failure(error), attempts: [])
            }
            await store.refreshProvider(.claude, allowDisabled: true)
            await store.refreshProvider(.claude, allowDisabled: true)
            #expect(fetches == 2)
            #expect(store.errors[.claude] == error.localizedDescription)
            #expect((store.snapshot(for: .claude) != nil) == hasPriorData)
            if hasPriorData {
                #expect(store.snapshot(for: .claude)?.primary == prior.primary)
                #expect(store.snapshot(for: .claude)?.secondary == prior.secondary)
                #expect(store.snapshot(for: .claude)?.updatedAt == prior.updatedAt)
                #expect(store.snapshot(for: .claude)?.identity?.accountEmail == prior.identity?.accountEmail)
            }
        }
    }

    @Test(arguments: [401, 403])
    func `explicit OAuth authentication rejection still invalidates prior quota`(statusCode: Int) async throws {
        let (error, _) = await Self.failure(statusCode: statusCode)
        #expect(error is ClaudeUsageError)
        #expect(!error.localizedDescription.contains("user:profile"))
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
        #expect(!UsageStore.isStartupConnectivityRetryableError(error))
        #expect(!ClaudeOAuthFetchStrategy().shouldFallback(on: error, context: Self.context()))
        try await ProviderTransportRegressionSupport.withStore(provider: .claude) { store, _ in
            store
                ._test_providerFetchOutcomeOverride = { _ in
                    ProviderFetchOutcome(result: .failure(error), attempts: [])
                }
            await store.refreshProvider(.claude, allowDisabled: true)
            await store.refreshProvider(.claude, allowDisabled: true)
            #expect(store.snapshot(for: .claude) == nil)
        }
    }

    @Test(arguments: [true, false])
    func `missing usage scope recommends a usable credential source`(locallyMissingScope: Bool) async {
        let (error, transport) = await Self.failure(
            statusCode: 403,
            responseBody: #"{"error":"Missing required scope user:profile"}"#,
            scopes: locallyMissingScope ? ["user:inference"] : ["user:profile"])
        #expect(await transport.requests().count == (locallyMissingScope ? 0 : 1))
        #expect(error is ClaudeUsageError)
        #expect(error.localizedDescription.contains("user:profile"))
        #expect(error.localizedDescription.contains("Claude Code sign-in"))
        #expect(error.localizedDescription.contains("OAuth token override"))
        #expect(!error.localizedDescription.contains("setup-token"))
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
        #expect(!UsageStore.isStartupConnectivityRetryableError(error))
        #expect(!ClaudeOAuthFetchStrategy().shouldFallback(on: error, context: Self.context()))
    }

    @Test(arguments: [429, 500])
    func `explicit OAuth preserves nontransport response errors`(statusCode: Int) async {
        let (error, _) = await Self.failure(statusCode: statusCode)
        #expect(error is ClaudeUsageError)
        #expect(!UsageStore.isStartupConnectivityRetryableError(error))
        #expect(UsageStore.refreshFailureHookStatus(error) == "error")
        #expect(!ClaudeOAuthFetchStrategy().shouldFallback(on: error, context: Self.context()))
    }

    private static func failure(
        underlying: Error? = nil,
        statusCode: Int = 500,
        responseBody: String = "{}",
        scopes: [String] = ["user:profile"]) async -> (Error, ProviderHTTPTransportStub)
    {
        let environment = ProviderTransportRegressionSupport.environment
        let transport = ProviderHTTPTransportStub { request in
            if let underlying { throw underlying }
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
            return (Data(responseBody.utf8), response)
        }
        let credentials = ClaudeOAuthCredentials(
            accessToken: "fixture-access-\(UUID().uuidString)",
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600),
            scopes: scopes,
            rateLimitTier: "fixture-tier",
            subscriptionType: "pro")
        let fetcher = Self.fetcher()
        let loadCredentials: @Sendable ([String: String], Bool, Bool) async throws
            -> ClaudeOAuthCredentials = { _, _, _ in
                credentials
            }
        let fetchUsage: @Sendable (String, Bool) async throws -> OAuthUsageResponse = { token, _ in
            try await ClaudeOAuthUsageFetcher.fetchUsage(
                accessToken: token,
                detectClaudeVersion: false,
                environment: environment,
                transport: transport)
        }
        let error = await ProviderTransportRegressionSupport.captureFailure {
            try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(loadCredentials) {
                try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchUsage) {
                    _ = try await fetcher.loadLatestUsage(model: "sonnet")
                }
            }
        }
        return (error, transport)
    }

    private static func fetcher() -> ClaudeUsageFetcher {
        ClaudeUsageFetcher(
            browserDetection: ProviderTransportRegressionSupport
                .browser(root: ProviderTransportRegressionFixtures.root),
            environment: ProviderTransportRegressionSupport.environment,
            runtime: .cli,
            dataSource: .oauth,
            preserveInvalidOAuthCache: true,
            useWebExtras: false)
    }

    private static func context() -> ProviderFetchContext {
        let environment = ProviderTransportRegressionSupport.environment
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .oauth,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: Self.fetcher(),
            browserDetection: ProviderTransportRegressionSupport
                .browser(root: ProviderTransportRegressionFixtures.root))
    }
}
