import Foundation
import Testing
@testable import CodexBarCore

struct CodexCustomAPIFetchStrategyTests {
    @Test
    func `usage url appends v1 when base url has no version`() throws {
        let url = try CodexCustomAPIFetchStrategy.usageURL(baseURL: #require(URL(string: "https://example.com")))
        #expect(url.absoluteString == "https://example.com/v1/usage")
    }

    @Test
    func `usage url does not double the v1 segment`() throws {
        let url = try CodexCustomAPIFetchStrategy.usageURL(baseURL: #require(URL(string: "https://example.com/v1")))
        #expect(url.absoluteString == "https://example.com/v1/usage")
    }

    @Test
    func `fetch maps response into usage and credits`() async throws {
        let json = """
        {
          "remaining": 104.52,
          "unit": "USD",
          "is_valid": true,
          "plan_name": "Pro Daily",
          "subscription": {
            "daily_limit_usd": 200,
            "daily_usage_usd": 95.48,
            "weekly_limit_usd": 500,
            "weekly_usage_usd": 125,
            "expires_at": "2026-07-09T00:00:00Z"
          }
        }
        """
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url?.absoluteString == "https://example.com/v1/usage")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            return (Data(json.utf8), response)
        }

        let snapshot = try await CodexCustomAPIFetchStrategy.fetchSnapshot(
            credentials: (baseURL: #require(URL(string: "https://example.com")), apiKey: "sk-test"),
            transport: transport,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(snapshot.credits.remaining == 104.52)
        #expect(snapshot.credits.codexCreditLimit?.title == "Daily limit")
        #expect(snapshot.usage.extraRateWindows?.count == 1)
        #expect(snapshot.usage.identity?.providerID == .codex)
    }

    @Test
    func `fetch throws api error on non 2xx`() async {
        let transport = ProviderHTTPTransportHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil)!
            return (Data("unavailable".utf8), response)
        }

        await #expect(throws: CodexCustomUsageError.self) {
            _ = try await CodexCustomAPIFetchStrategy.fetchSnapshot(
                credentials: (baseURL: #require(URL(string: "https://example.com")), apiKey: "sk-test"),
                transport: transport)
        }
    }

    @Test
    func `is available returns false when credentials cannot resolve`() async {
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            includeOptionalUsage: false,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: ["CODEX_HOME": "/nonexistent-codex-home-\(UUID().uuidString)"],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0)),
            browserDetection: BrowserDetection(cacheTTL: 0))
        let strategy = CodexCustomAPIFetchStrategy()
        #expect(await strategy.isAvailable(context) == false)
    }

    @Test
    func `is available returns true when credentials resolve`() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: home)
        }
        try """
        model_provider = "OpenAI"
        [model_providers.OpenAI]
        base_url = "https://example.com"
        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try #"{"OPENAI_API_KEY":"sk-test"}"#.write(
            to: home.appendingPathComponent("auth.json"),
            atomically: true,
            encoding: .utf8)

        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            includeOptionalUsage: false,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: ["CODEX_HOME": home.path],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0)),
            browserDetection: BrowserDetection(cacheTTL: 0))
        let strategy = CodexCustomAPIFetchStrategy()
        #expect(await strategy.isAvailable(context))
    }

    @Test
    func `resolve strategies returns custom strategy for api source mode`() async {
        // The custom source is opt-in: .auto must still resolve to OAuth/CLI,
        // never the custom strategy.
        let autoContext = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            includeOptionalUsage: false,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0)),
            browserDetection: BrowserDetection(cacheTTL: 0))
        let autoStrategies = await CodexProviderDescriptor.descriptor.fetchPlan.pipeline
            .resolveStrategies(autoContext)
        #expect(autoStrategies.map(\.id) == ["codex.oauth", "codex.cli"])

        let apiContext = ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            includeOptionalUsage: false,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0)),
            browserDetection: BrowserDetection(cacheTTL: 0))
        let apiStrategies = await CodexProviderDescriptor.descriptor.fetchPlan.pipeline
            .resolveStrategies(apiContext)
        #expect(apiStrategies.map(\.id) == ["codex.custom"])
    }
}
