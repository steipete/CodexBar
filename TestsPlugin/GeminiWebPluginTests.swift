import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct GeminiWebPluginTests {
    private static let usage = #"""
    )]}'
    [{"data":{"viewer":{"rpcs":{"getUsageInfo":{"subscriptionTier":"TIER1","pools":[
      {"poolType":"GXU_FIVE_HOURLY","percentageUsed":0.24,
       "gxu":{"windowRefreshesAt":"2026-10-15T05:43:53.558200Z"}},
      {"poolType":"GXU_WEEKLY","percentageUsed":0.01786011,
       "gxu":{"windowRefreshesAt":"2026-10-21T04:43:53.558273Z"}}
    ]}}}},"errors":[{"message":"Unrelated upsell unavailable"}]}]
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Gemini app query maps fractions and stops at the first validated session`(
        engine: ProviderPluginEngineKind) async throws
    {
        let fixture = Fixture([(200, Self.usage), (200, "must not be requested")])
        let usage = try await Self.fetch(engine, fixture: fixture)
        #expect(usage.primary?.usedPercent == 24)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt != nil)
        #expect(abs((usage.secondary?.usedPercent ?? -1) - 1.786011) < 0.000_001)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.secondary?.resetsAt != nil)
        #expect(usage.identity?.loginMethod == "Pro")
        #expect(usage.identity?.accountEmail == nil)
        #expect(await fixture.requests == 1)
        #expect(await fixture.sessions == 1)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unknown windows stay absent while a reported zero remains zero`(
        engine: ProviderPluginEngineKind) async throws
    {
        let body = #"""
        [{"data":{"viewer":{"rpcs":{"getUsageInfo":{"subscriptionTier":"UNRECOGNIZED","pools":[
          {"poolType":"GXU_FIVE_HOURLY","percentageUsed":null},
          {"poolType":"GXU_WEEKLY","percentageUsed":0,"gxu":{"windowRefreshesAt":"unknown"}}
        ]}}}}}]
        """#
        let usage = try await Self.fetch(engine, fixture: Fixture([(200, body)]))
        #expect(usage.primary == nil)
        #expect(usage.secondary?.usedPercent == 0)
        #expect(usage.secondary?.resetsAt == nil)
        #expect(usage.identity?.loginMethod == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `accounts without reported quota do not manufacture empty bars`(engine: ProviderPluginEngineKind) async {
        let body = #"[{"data":{"viewer":{"rpcs":{"getUsageInfo":{"pools":[]}}}}}]"#
        let fixture = Fixture([(200, body), (200, Self.usage)])
        await #expect {
            try await Self.fetch(engine, fixture: fixture)
        } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == .providerUnavailable }
        #expect(await fixture.requests == 1)
        #expect(await fixture.sessions == 1)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `signed out sessions allow the next browser candidate`(engine: ProviderPluginEngineKind) async throws {
        let fixture = Fixture([(200, #"[{"data":{"viewer":null}}]"#), (200, Self.usage)])
        let usage = try await Self.fetch(engine, fixture: fixture)
        #expect(usage.primary?.usedPercent == 24)
        #expect(await fixture.requests == 2)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `query drift stops browser traversal without echoing the response`(engine: ProviderPluginEngineKind) async {
        let fixture = Fixture([
            (200, #"[{"data":{},"errors":[{"message":"private-response"}]}]"#),
            (200, Self.usage),
        ])
        await #expect {
            try await Self.fetch(engine, fixture: fixture)
        } throws: { error in
            guard let error = error as? ProviderFetchClassifiedError else { return false }
            return error.kind == .parseFailure && !error.message.contains("private-response")
        }
        #expect(await fixture.requests == 1)
        #expect(await fixture.sessions == 1)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `HTML server errors keep their HTTP classification`(engine: ProviderPluginEngineKind) async {
        let fixture = Fixture([(503, "<html>Temporarily unavailable</html>")])
        await #expect {
            try await Self.fetch(engine, fixture: fixture)
        } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == .providerUnavailable }
        // The host may retry this GET once; it must never try another browser's identity.
        #expect(await fixture.sessions == 1)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `disabled cookies never read a browser and sessions stay nonpersistent`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "gemini-web", engine: engine, transport: Fixture([(200, Self.usage)]))
        let policy = try #require(runtime.manifest.cookiePolicy)
        #expect(policy.cache == .nonpersistent)
        #expect(policy.allowsImportAttempt(runtime: .app, interaction: .background))
        await #expect {
            try await runtime.fetchUsage(cookieSource: .off, cookieSessionResolver: { _, _ in
                Issue.record("Disabled Gemini cookies reached the browser")
                return nil
            })
        } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == .missingCredential }
    }

    private static func fetch(_ engine: ProviderPluginEngineKind, fixture: Fixture) async throws -> UsageSnapshot {
        let runtime = try BundledPluginTestSupport.runtime("gemini-web", engine: engine, transport: fixture)
        return try await runtime.fetchUsage(cookieSessionResolver: { _, _ in await fixture.nextSession() })
    }

    private actor Fixture: ProviderHTTPTransport {
        let responses: [(Int, String)]
        var sessions = 0
        var requests = 0

        init(_ responses: [(Int, String)]) {
            self.responses = responses
        }

        func nextSession() -> ProviderPluginCookieSession? {
            guard self.sessions < self.responses.count else { return nil }
            self.sessions += 1
            return .init(
                header: "SID=fixture-\(self.sessions)",
                source: "Synthetic",
                origin: "https://gemini.google.com")
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            #expect(url.host == "gemini.google.com")
            #expect(url.path == "/_/BardChatUi/graphql/schemas/GEMINI_WEB_GRAPHQL/executeQuery")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "SID=fixture-\(self.sessions)")
            let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(query.first { $0.name == "query_signature" }?.value ==
                "2/dWbCvkVB0X16r9NPnxifeOAAqdCqMf0xeWvau9yPy7g=")
            let variables = try #require(query.first { $0.name == "variables" }?.value)
            let actual = try #require(JSONSerialization.jsonObject(with: Data(variables.utf8)) as? NSDictionary)
            let expected = try #require(JSONSerialization.jsonObject(with: Data(#"""
            {"g1Request":{"entrypoints":["GEMINI_USAGE_SETTINGS_UPGRADE_BANNER"]},
             "workspaceRequest":{"recommendationsForSurfaceRequests":[]}}
            """#.utf8)) as? NSDictionary)
            #expect(actual == expected)
            let (code, body) = self.responses[min(self.requests, self.responses.count - 1)]
            self.requests += 1
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: code, httpVersion: nil, headerFields: ["Retry-After": "0"])))
        }
    }
}
