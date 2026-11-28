import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

@Suite
struct MistralBudgetAPITests {
    private static let budgetJSON = #"""
    {
      "api_budget": {"usage_percentage": 12.5, "initial_budget": 40, "currency": "eur"},
      "vibe_budget": {"usage_percentage": 3, "initial_budget": 200, "currency": "eur"}
    }
    """#

    @Test
    func `API key alone publishes allowances without cookies or billing spend`() async throws {
        let strategy = MistralBudgetFetchStrategy(transport: ProviderHTTPTransportHandler { request in
            #expect(request.url?.absoluteString == "https://api.mistral.ai/v1/billing/budget")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(!request.httpShouldHandleCookies)
            return try Self.response(request, status: 200, body: Self.budgetJSON)
        })
        let context = Self.context(sourceMode: .auto, env: ["MISTRAL_API_KEY": " synthetic-key "])
        #expect(await strategy.isAvailable(context))
        let result = try await strategy.fetch(context)
        #expect(result.sourceLabel == "api")
        #expect(result.usage.primary?.usedPercent == 12.5)
        #expect(result.usage.extraRateWindows?.first { $0.id == "mistral-monthly-plan" }?.window.usedPercent == 3)
        #expect(result.usage.mistralUsage == nil)
    }

    @Test(arguments: [401, 403, 500])
    func `auto falls back to browser usage without exposing error bodies`(status: Int) async throws {
        let api = MistralBudgetFetchStrategy(transport: ProviderHTTPTransportHandler { request in
            try Self.response(request, status: status, body: "synthetic-private-response")
        })
        let web = MistralWebFetchStrategy(transport: ProviderHTTPTransportHandler { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "ory_session_test=synthetic-session")
            if request.url?.path == "/api/billing/v2/usage" {
                return try Self.response(request, status: 200, body: #"{"currency":"EUR","completion":{"models":{}}}"#)
            }
            return try Self.response(request, status: 404, body: "synthetic-private-response")
        })
        let pipeline = ProviderFetchPipeline(resolveStrategies: { _ in [api, web] })
        let outcome = await pipeline.fetch(
            context: Self.context(sourceMode: .auto, env: ["MISTRAL_API_KEY": "synthetic-key"]),
            provider: .mistral)
        let result = try outcome.result.get()
        #expect(result.sourceLabel == "web")
        #expect(result.usage.mistralUsage != nil)
        #expect(result.usage.primary == nil)
        #expect(!outcome.attempts.compactMap(\.errorDescription).joined().contains("synthetic-private-response"))
        let diagnostic = try #require(result.diagnostic)
        #expect(!diagnostic.contains("synthetic-private-response"))
        if status == 500 {
            #expect(diagnostic.contains("HTTP 500"))
        } else {
            #expect(diagnostic.contains("rejected the API key"))
        }
    }

    @Test
    func `partial browser usage preserves the rejected key explanation`() async throws {
        let privateBody = "synthetic-private-response"
        let api = MistralBudgetFetchStrategy(transport: ProviderHTTPTransportHandler { request in
            try Self.response(request, status: 403, body: privateBody)
        })
        let web = MistralWebFetchStrategy(transport: ProviderHTTPTransportHandler { request in
            switch request.url?.path {
            case "/api/billing/v2/usage": try Self.response(request, status: 500, body: privateBody)
            case "/api/billing/credits":
                try Self.response(request, status: 200, body: #"{"wallet_amount":40,"currency":"EUR"}"#)
            default: try Self.response(request, status: 404, body: privateBody)
            }
        })
        let result = try await ProviderFetchPipeline(resolveStrategies: { _ in [api, web] }).fetch(
            context: Self.context(sourceMode: .auto, env: ["MISTRAL_API_KEY": "synthetic-key"]),
            provider: .mistral).result.get()
        #expect(result.sourceLabel == "web")
        #expect(result.usage.mistralUsage == nil)
        #expect(result.usage.details.first?.rows.first?.usageValue == 40)
        let diagnostic = try #require(result.diagnostic)
        #expect(diagnostic.contains("rejected the API key"))
        #expect(diagnostic.contains("HTTP 500"))
        #expect(!diagnostic.contains(privateBody))
    }

    @Test
    func `a canceled budget request does not fall back to browser cookies`() async {
        let api = MistralBudgetFetchStrategy(transport: ProviderHTTPTransportHandler { _ in
            throw URLError(.cancelled)
        })
        let web = MistralWebFetchStrategy(transport: ProviderHTTPTransportHandler { _ in
            Issue.record("Unexpected browser request")
            throw URLError(.unsupportedURL)
        })
        let pipeline = ProviderFetchPipeline(resolveStrategies: { _ in [api, web] })
        let outcome = await pipeline.fetch(
            context: Self.context(sourceMode: .auto, env: ["MISTRAL_API_KEY": "synthetic-key"]),
            provider: .mistral)
        #expect(throws: CancellationError.self) { try outcome.result.get() }
        #expect(outcome.attempts.map(\.strategyID) == ["mistral.api"])
    }

    @Test
    func `malformed key is rejected before sending a request`() async {
        await #expect(throws: MistralBudgetError.invalidKey) {
            try await MistralUsageFetcher.fetchBudget(
                apiKey: "key\nInjected: 1",
                transport: ProviderHTTPTransportHandler { _ in
                    Issue.record("Unexpected request with malformed key")
                    throw URLError(.unsupportedURL)
                })
        }
    }

    @Test
    func `parses a root allowance and ignores a malformed sibling`() throws {
        let json = #"{"usage_percentage":42,"initial_budget":100,"currency":"usd","vibe_budget":false}"#
        let budgets = try MistralUsageFetcher.parseBudget(data: Data(json.utf8))
        #expect(budgets.api?.remainingAmount == 58)
        #expect(budgets.api?.currencyCode == "USD")
        #expect(budgets.vibe == nil)
    }

    @Test
    func `keeps Vibe if the nested API allowance is unusable`() throws {
        let json = #"""
        {
          "api_budget": {"usage_percentage": 0, "initial_budget": 0, "currency": "EUR"},
          "vibe_budget": {"usage_percentage": 3, "initial_budget": 200, "currency": "EUR"}
        }
        """#
        let budgets = try MistralUsageFetcher.parseBudget(data: Data(json.utf8))
        #expect(budgets.api == nil)
        #expect(budgets.vibe?.usedAmount == 6)
    }

    @Test(arguments: [#"{"detail":"error"}"#, #"{"api_budget":{"usage_percentage":0,"initial_budget":0}}"#])
    func `unusable budget does not report zero usage`(json: String) {
        #expect(throws: MistralBudgetError.noBudget) {
            try MistralUsageFetcher.parseBudget(data: Data(json.utf8))
        }
    }

    @Test
    func `subscription record accepts a React encoded reset date`() throws {
        let budget = ["api_budget": [
            "usage_percentage": 2,
            "initial_budget": 25.5,
            "currency": "eur",
            "reset_at": "$D2026-12-01T00:00:00.000Z",
        ] as [String: Any]]
        let row = try JSONSerialization.data(withJSONObject: ["budget": budget])
        let json = try #require(String(bytes: row, encoding: .utf8))
        let record = "7:\(json)\n"
        let encoded = try JSONSerialization.data(withJSONObject: [1, record])
        let chunk = try #require(String(bytes: encoded, encoding: .utf8))
        let budgets = try MistralSubscriptionBudgetParser.parse(html: "<script>self.__next_f.push(\(chunk))</script>")
        let expected = try #require(ISO8601DateParser.parse("2026-12-01T00:00:00.000Z"))
        #expect(budgets.api?.resetsAt == expected)
    }

    @Test(arguments: [ProviderSourceMode.auto, .api, .web])
    func `descriptor respects explicit source selection`(mode: ProviderSourceMode) async {
        let pipeline = MistralProviderDescriptor.descriptor.fetchPlan.pipeline
        let strategies = await pipeline.resolveStrategies(Self.context(sourceMode: mode))
        let expected = switch mode {
        case .api: ["mistral.api"]
        case .web: ["mistral.web"]
        default: ["mistral.api", "mistral.web"]
        }
        #expect(strategies.map(\.id) == expected)
    }

    @Test
    func `selected cookie accounts do not inherit the configured key`() {
        let config = ProviderConfig(id: .mistral, apiKey: "synthetic-key")
        let account = ProviderTokenAccount(
            id: UUID(), label: "Test", token: "ory_session_test=synthetic-session", addedAt: 0, lastUsed: nil)
        let unscoped = ProviderEnvironmentResolver.resolve(
            base: [:], provider: .mistral, config: config, selectedAccount: nil)
        let scoped = ProviderEnvironmentResolver.resolve(
            base: [:], provider: .mistral, config: config, selectedAccount: account)
        #expect(unscoped["MISTRAL_API_KEY"] == "synthetic-key")
        #expect(scoped["MISTRAL_API_KEY"] == nil)
    }

    private static func response(_ request: URLRequest, status: Int, body: String) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }

    private static func context(sourceMode: ProviderSourceMode, env: [String: String] = [:]) -> ProviderFetchContext {
        let browser = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 2,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: .make(mistral: .init(
                cookieSource: .manual, manualCookieHeader: "ory_session_test=synthetic-session")),
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browser),
            browserDetection: browser)
    }
}
