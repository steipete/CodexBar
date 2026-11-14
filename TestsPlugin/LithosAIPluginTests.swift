import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct LithosAIPluginTests {
    private static let now = Date(timeIntervalSince1970: 1_800_489_600) // 2027-01-21 UTC

    @Test(arguments: BundledPluginTestSupport.engines)
    func `console balance and sparse spend preserve nanodollars and organization`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(engine, fixture: Fixture(spend: """
        {"start":"2027-01-01","end":"2027-01-21","days":[
          {"day":"2027-01-21","modelId":"fixture-model","nanos":260066994},
          {"day":"2027-01-21","modelId":"fixture-other","nanos":100000000},
          {"day":"2027-01-03","modelId":"fixture-model","nanos":2000000000}]}
        """))
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.providerCost?.used == 4.70709986)
        #expect(usage.providerCost?.currencyCode == "USD")
        #expect(usage.providerCost?.limit == 0)
        #expect(usage.identity?.accountEmail == "person@example.test")
        #expect(usage.identity?.accountOrganization == "Synthetic Organization")
        let rows = usage.details.flatMap(\.rows)
        #expect(rows.first { $0.label == "Today (UTC)" }?.value == "$0.36")
        #expect(rows.first { $0.label == "This month (UTC)" }?.value == "$2.36")
        #expect(rows.first { $0.label == "Balance" }?.value == "$4.71")
    }

    @Test(arguments: ["0", "-1000000000", "1000000"], BundledPluginTestSupport.engines)
    func `zero debt and subcent balances are not invented quotas`(balance: String, engine: ProviderPluginEngineKind)
        async throws
    {
        let usage = try await Self.fetch(engine, fixture: Fixture(balance: balance))
        #expect(usage.providerCost?.used == Double(balance)! / 1e9)
        #expect(usage.primary == nil)
        #expect(usage.details.flatMap(\.rows).first { $0.label == "Today (UTC)" }?.value == "$0.00")
        if balance == "1000000" {
            #expect(usage.details.flatMap(\.rows).first { $0.label == "Balance" }?.value == "Less than $0.01")
        }
    }

    @Test(arguments: ["null", "\"4707099860\"", "0.5", "1e99"], BundledPluginTestSupport.engines)
    func `malformed required balance fails closed`(balance: String, engine: ProviderPluginEngineKind) async {
        await #expect {
            try await Self.fetch(engine, fixture: Fixture(balance: balance))
        } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == .parseFailure }
    }

    @Test(
        arguments: [
            "not-json",
            "{}",
            "{\"days\":null}",
            "{\"start\":\"2027-01-01\",\"end\":\"2027-01-21\",\"days\":[{\"day\":\"2027-01-22\",\"nanos\":1}]}"
        ],
        BundledPluginTestSupport.engines)
    func `optional malformed spend preserves balance without reporting false zero`(
        spend: String, engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(engine, fixture: Fixture(spend: spend))
        #expect(usage.providerCost?.used == 4.70709986)
        #expect(usage.details.flatMap(\.rows).first { $0.label == "Spend" }?.value == "Unavailable")
        #expect(!usage.details.flatMap(\.rows).contains { $0.label == "Today (UTC)" })
    }

    @Test(arguments: [1, 2, 3], BundledPluginTestSupport.engines)
    func `expired session advances to the next profile`(request: Int, engine: ProviderPluginEngineKind) async throws {
        let fixture = Fixture(firstStatus: 401, statusAtRequest: request)
        _ = try await Self.fetch(engine, fixture: fixture)
        #expect(await fixture.rejections == 1)
        #expect(await fixture.sessions == 2)
    }

    @Test(arguments: [403, 429, 500], BundledPluginTestSupport.engines)
    func `non authentication failures do not reject profiles`(status: Int, engine: ProviderPluginEngineKind) async {
        let fixture = Fixture(firstStatus: status)
        let expected: ProviderFetchClassifiedError.Kind = status == 403 ? .permissionDenied :
            (status == 429 ? .rateLimited : .providerUnavailable)
        await #expect {
            try await Self.fetch(engine, fixture: fixture)
        } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == expected }
        #expect(await fixture.rejections == 0)
        #expect(await fixture.sessions == 1)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `disabled cookies never call the broker`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime("lithosai", engine: engine, transport: Fixture())
        await #expect {
            try await runtime.fetchUsage(cookieSource: .off, cookieSessionResolver: { _, _ in
                Issue.record("Disabled cookies reached the broker")
                return nil
            })
        } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == .missingCredential }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `automatic source retains access gated background refreshes`(engine: ProviderPluginEngineKind) throws {
        let runtime = try BundledPluginTestSupport.runtime("lithosai", engine: engine, transport: Fixture())
        let policy = try #require(runtime.manifest.cookiePolicy)
        #expect(policy.allowsImportAttempt(runtime: .app, interaction: .background))
        #expect(policy.cache == .nonpersistent)
        #expect(policy.requiredCookies == ["__Host-console_session", "__Host-console_csrf"])
    }

    private static func fetch(_ engine: ProviderPluginEngineKind, fixture: Fixture) async throws -> UsageSnapshot {
        let runtime = try BundledPluginTestSupport.runtime("lithosai", engine: engine, transport: fixture)
        return try await runtime.fetchUsage(
            now: Self.now,
            cookieSessionResolver: { _, _ in await fixture.nextSession() },
            cookieSessionInvalidator: { _, _ in fixture.rejected.increment() })
    }

    private actor Fixture: ProviderHTTPTransport {
        let balance: String
        let spend: String
        let firstStatus: Int
        let statusAtRequest: Int
        var sessions = 0
        let rejected = Counter()
        var rejections: Int {
            self.rejected.value
        }

        var requests = 0

        init(
            balance: String = "4707099860",
            spend: String = #"{"start":"2027-01-01","end":"2027-01-21","days":[]}"#,
            firstStatus: Int = 200,
            statusAtRequest: Int = 1)
        {
            self.balance = balance
            self.spend = spend
            self.firstStatus = firstStatus
            self.statusAtRequest = statusAtRequest
        }

        func nextSession() -> ProviderPluginCookieSession? {
            self.sessions += 1
            guard self.sessions <= 2 else { return nil }
            return .init(
                header: "__Host-console_session=fixture-\(self.sessions); __Host-console_csrf=csrf-\(self.sessions)",
                source: "Synthetic", origin: "https://console.lithosai.cloud")
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            #expect(request.httpMethod == "GET")
            #expect(url.host == "console.lithosai.cloud")
            #expect(request.value(forHTTPHeaderField: "X-Console-Csrf") == "csrf-\(self.sessions)")
            #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("fixture-\(self.sessions)") == true)
            self.requests += 1
            let code = self.requests == self.statusAtRequest ? self.firstStatus : 200
            let body: String
            switch url.path {
            case "/api/me":
                #expect(request.value(forHTTPHeaderField: "X-Organization-Id") == nil)
                body = #"{"user":{"email":"person@example.test"},"activeOrganization":{"id":"org-fixture","name":"Synthetic Organization"}}"#
            case "/api/billing":
                #expect(request.value(forHTTPHeaderField: "X-Organization-Id") == "org-fixture")
                body = "{\"balanceNanos\":\(self.balance),\"hasCard\":true,\"onHold\":false}"
            case "/api/billing/spend":
                #expect(request.value(forHTTPHeaderField: "X-Organization-Id") == "org-fixture")
                #expect(url.query == "start=2027-01-01&end=2027-01-21")
                body = self.spend
            default:
                Issue.record("Unexpected fixture request")
                throw URLError(.badURL)
            }
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])))
        }
    }
}
