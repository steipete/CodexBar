import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeSubscriptionCLITests {
    enum Scenario: CaseIterable {
        case renewal, expiration, empty, unavailable, malformed, changedAccount, changedOrganization, stalled
    }

    actor Server {
        let scenario: Scenario
        var billed = false
        var requests: [String] = []
        static let org = "11111111-1111-4111-8111-111111111111"
        static let otherOrg = "22222222-2222-4222-8222-222222222222"
        init(_ scenario: Scenario) { self.scenario = scenario }

        func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            self.requests.append(url.path)
            let body: String
            var code = 200
            switch url.path {
            case "/api/oauth/profile":
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-environment-oauth")
                let org = self.billed && self.scenario == .changedOrganization ? Self.otherOrg : Self.org
                body = """
                {"account":{"uuid":"fixture-account","email_address":"fixture@example.com"},
                 "organization":{"uuid":"\(org)"}}
                """
            case "/api/organizations":
                body = """
                [{"uuid":"\(Self.org)","name":"Fixture","capabilities":["chat"]}]
                """
            case "/api/organizations/\(Self.org)/usage":
                body = #"{"five_hour":{"utilization":11}}"#
            case "/api/organizations/\(Self.org)/overage_spend_limit":
                body = "{}"
                code = 404
            case "/api/account":
                let email = self.billed && self.scenario == .changedAccount
                    ? "other@example.com" : "fixture@example.com"
                let account = self.billed && self.scenario == .changedAccount ? "other-account" : "fixture-account"
                body = """
                {"uuid":"\(account)","email_address":"\(email)","memberships":[
                  {"organization":{"uuid":"\(Self.org)","billing_type":"stripe_subscription"}},
                  {"organization":{"uuid":"\(Self.otherOrg)"}}]}
                """
            case "/api/organizations/\(Self.org)/subscription_details":
                self.billed = true
                if self.scenario == .stalled {
                    try await Task.sleep(for: .seconds(60))
                    throw CancellationError()
                }
                if self.scenario == .unavailable { code = 403 }
                let end = self.scenario == .expiration ? "\"2026-11-05\"" : "null"
                let renewal = self.scenario == .empty ? "null" : "\"2026-11-05\""
                body = self.scenario == .malformed ? "{}" : """
                {"status":"active","next_charge_at":null,"next_charge_date":\(renewal),
                 "plan_ending_at":null,"plan_ending_before":\(end)}
                """
            default:
                Issue.record("Unexpected fixture request: \(url.path)")
                body = "{}"
                code = 404
            }
            if url.host == "claude.ai" {
                #expect(request.value(forHTTPHeaderField: "Cookie") == "sessionKey=sk-ant-sid01-synthetic")
            }
            if self.billed || url.path == "/api/oauth/profile" {
                #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            }
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: code, httpVersion: nil, headerFields: nil)))
        }
    }

    private func fetch(
        _ server: Server,
        runtime: ProviderRuntime = .cli,
        source: ProviderSourceMode = .web,
        cookies: ProviderCookieSource = .manual) async throws -> ProviderFetchResult
    {
        let browser = BrowserDetection(cacheTTL: 0)
        let environment = [ClaudeOAuthCredentialsStore.environmentTokenKey: "synthetic-environment-oauth"]
        let context = ProviderFetchContext(
            runtime: runtime,
            sourceMode: source,
            includeCredits: false,
            includeOptionalUsage: false,
            webTimeout: 10,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: ProviderSettingsSnapshot.make(claude: .init(
                usageDataSource: source == .web ? .web : .oauth,
                webExtrasEnabled: false,
                cookieSource: cookies,
                manualCookieHeader: "sessionKey=sk-ant-sid01-synthetic")),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browser, environment: [:]),
            browserDetection: browser)
        let transport = ProviderHTTPTransportHandler { try await server.respond($0) }
        let usage: @Sendable (String, Bool) async throws -> OAuthUsageResponse = { token, _ in
            #expect(token == "synthetic-environment-oauth")
            return try ClaudeOAuthUsageFetcher.decodeUsageResponse(Data(#"{"five_hour":{"utilization":11}}"#.utf8))
        }
        return try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
            try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(usage) {
                if source == .oauth { return try await ClaudeOAuthFetchStrategy().fetch(context) }
                return try await ClaudeWebFetchStrategy(browserDetection: browser).fetch(context)
            }
        }
    }

    @Test(arguments: [ProviderRuntime.cli, .app], [ProviderSourceMode.web, .oauth])
    func `web and accepted OAuth credentials export the same billing JSON`(
        _ runtime: ProviderRuntime, _ source: ProviderSourceMode) async throws
    {
        let result = try await self.fetch(Server(.renewal), runtime: runtime, source: source)
        #expect(result.usage.primary?.usedPercent == 11)
        #expect(result.usage.identity?.providerID == .claude)
        #expect(result.usage.subscriptionRenewsAt == ISO8601DateFormatter().date(from: "2026-11-05T00:00:00Z"))
        #expect(result.usage.subscriptionRenewsAtIsDateOnly)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try #require(JSONSerialization.jsonObject(with: encoder.encode(result.usage)) as? [String: Any])
        #expect(json["subscriptionRenewsAt"] as? String == "2026-11-05T00:00:00Z")
        #expect(json["subscriptionRenewsAtIsDateOnly"] as? Bool == true)
        #expect(json["subscriptionExpiresAt"] == nil)
    }

    @Test(arguments: Scenario.allCases, [ProviderSourceMode.web, .oauth])
    func `billing failures and authority changes preserve accepted quota`(
        _ scenario: Scenario, _ source: ProviderSourceMode) async throws
    {
        let result = try await self.fetch(Server(scenario), source: source)
        #expect(result.usage.primary?.usedPercent == 11)
        let hasRenewal = scenario == .renewal || (source == .web && scenario == .changedOrganization)
        #expect((result.usage.subscriptionRenewsAt != nil) == hasRenewal)
        #expect((result.usage.subscriptionExpiresAt != nil) == (scenario == .expiration))
    }

    @Test func `cookie source off makes no billing request for OAuth`() async throws {
        let server = Server(.renewal)
        let result = try await self.fetch(server, source: .oauth, cookies: .off)
        #expect(result.usage.primary?.usedPercent == 11)
        #expect(result.usage.subscriptionRenewsAt == nil)
        #expect(await server.requests.isEmpty)
    }

    @Test func `optional deadline cannot discard successful quota`() async throws {
        let result = try await ClaudeSubscriptionMetadataFetcher.$timeoutForTesting.withValue(.zero) {
            try await self.fetch(Server(.stalled))
        }
        #expect(result.usage.primary?.usedPercent == 11)
        #expect(result.usage.subscriptionRenewsAt == nil)
    }
}
