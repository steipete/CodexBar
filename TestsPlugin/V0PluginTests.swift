import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct V0PluginTests {
    #if canImport(JavaScriptCore)
    private static let engines: [ProviderPluginEngineKind] = [.quickJS, .javaScriptCore]
    #else
    private static let engines: [ProviderPluginEngineKind] = [.quickJS]
    #endif

    private static let tokenBilling = #"""
    {"billingType":"token","data":{"balance":{"remaining":750,"total":1000},
    "billingCycle":{"start":1797325200,"end":1800003600}}}
    """#
    private static let rateLimits = #"{"remaining":80,"reset":1800001800,"limit":100}"#

    @Test(arguments: Self.engines)
    func `token billing and rate limit windows retain unit neutral balances`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(engine: engine, scope: "project-demo")
        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_800_003_600))
        #expect(snapshot.secondary?.usedPercent == 20)
        #expect(snapshot.secondary?.resetsAt == Date(timeIntervalSince1970: 1_800_001_800))
        #expect(snapshot.identity?.loginMethod == "API key")
        #expect(snapshot.identity?.providerID == .v0)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.dataConfidence == UsageDataConfidence.exact)
        let details = try #require(snapshot.details.first)
        #expect(details.title == "v0 API")
        #expect(details.rows.contains { $0.label == "Billing remaining" && $0.value == "750" })
        #expect(details.rows.contains { $0.label == "Billing type" && $0.value == "token" })
        #expect(details.rows.contains { $0.label == "Scope" && $0.value == "project-demo" })
    }

    @Test(arguments: Self.engines)
    func `on demand balances remain separate from billing allowance and its reset`(
        engine: ProviderPluginEngineKind) async throws
    {
        for balance in [0, 10] {
            let snapshot = try await Self.fetch(
                engine: engine,
                billing: """
                {"billingType":"token","data":{"balance":{"remaining":0,"total":20},
                "billingCycle":{"end":1800003600},"onDemand":{"balance":\(balance),
                "blocks":[{"effectiveDate":1790000000,"originalBalance":100,"currentBalance":50}]}}}
                """)
            #expect(snapshot.primary?.usedPercent == 100)
            #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_800_003_600))
            #expect(snapshot.providerCost == nil)
            let row = try #require(snapshot.details.first?.rows.first { $0.label == "On-demand balance" })
            #expect(row.value == String(balance))
            #expect(row.secondaryValue == nil)
        }
    }

    @Test(arguments: Self.engines)
    func `legacy billing without remaining preserves its limit and independent quota`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(
            engine: engine, billing: #"{"billingType":"legacy","data":{"limit":1000}}"#)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == 20)
        let row = try #require(snapshot.details.first?.rows.first)
        #expect(row.label == "Billing remaining")
        #expect(row.value == "Unavailable")
        #expect(row.secondaryValue == "limit 1,000")
    }

    @Test(arguments: Self.engines)
    func `legacy zero allowance and unknown rate remaining do not invent balances`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(
            engine: engine,
            billing: #"{"billingType":"legacy","data":{"remaining":0,"reset":0,"limit":0}}"#,
            rateLimits: #"{"limit":100}"#, scope: "   ")
        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.primary?.resetsAt == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.details.first?.rows.contains { $0.label == "Scope" } == false)
    }

    @Test(arguments: Self.engines)
    func `scope is encoded as one query value and trimmed`(engine: ProviderPluginEngineKind) async throws {
        _ = try await Self.fetch(engine: engine, scope: " project / demo&extra=value ")
    }

    @Test(arguments: [
        #"{"billingType":"token"}"#,
        #"{"billingType":"token","data":{"billingCycle":{"end":1800003600}}}"#,
        #"{"billingType":"token","data":{"balance":{"remaining":0,"total":20},"billingCycle":{},"onDemand":{"balance":"10"}}}"#,
        #"{"billingType":"token","data":{"balance":{"remaining":0,"total":20},"billingCycle":{},"onDemand":{"balance":1e400}}}"#,
        #"{"billingType":"legacy","data":{"remaining":1}}"#,
        #"{"billingType":"unknown","data":{"remaining":1,"limit":2}}"#,
        #"{"data":{"remaining":1,"limit":2}}"#,
        "<html>private upstream response</html>",
    ], Self.engines)
    func `malformed successful billing fails without leaking response bodies`(
        billing: String, engine: ProviderPluginEngineKind) async
    {
        do {
            _ = try await Self.fetch(engine: engine, billing: billing)
            Issue.record("Expected malformed billing to fail")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
            #expect(!error.message.contains("private upstream response"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired, ""),
        (403, .permissionDenied, "<html>Forbidden</html>"),
        (503, .providerUnavailable, "<html>Unavailable</html>"),
    ], Self.engines)
    func `HTTP failures are classified before decoding either endpoint`(
        failure: (Int, ProviderFetchClassifiedError.Kind, String), engine: ProviderPluginEngineKind) async
    {
        for endpoint in ["/v1/user/billing", "/v1/rate-limits"] {
            do {
                _ = try await Self.fetch(
                    engine: engine, failurePath: endpoint, statusCode: failure.0, errorBody: failure.2)
                Issue.record("Expected HTTP failure")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == failure.1)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test(arguments: [("3600", 10.0), ("3", 3.0), ("invalid", 1.0), ("-1", 1.0)], Self.engines)
    func `rate limiting preserves a bounded retry delay without requiring JSON`(
        fixture: (String, Double), engine: ProviderPluginEngineKind) async
    {
        do {
            _ = try await Self.fetch(
                engine: engine, failurePath: "/v1/user/billing", statusCode: 429,
                errorBody: "", retryAfter: fixture.0)
            Issue.record("Expected rate limit failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .rateLimited)
            #expect(error.retryAfterSeconds == fixture.1)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `descriptor projects config key and project scope without changing unrelated environment`() throws {
        let credentials = try #require(V0ProviderDescriptor.descriptor.credentials)
        let environment = credentials.applyConfig(
            base: ["V0_API_KEY": "environment-key", "V0_SCOPE": "old-project", "OTHER": "preserved"],
            config: ProviderConfig(id: .v0, apiKey: " fixture-key ", workspaceID: " project-demo "))
        #expect(environment == ["V0_API_KEY": "fixture-key", "V0_SCOPE": "project-demo", "OTHER": "preserved"])
        #expect(credentials.resolveToken(environment: environment)?.token == "fixture-key")
        #expect(V0SettingsReader.scope(environment: environment) == "project-demo")
        #expect(V0SettingsReader.apiKey(environment: ["V0_API_KEY": " \n"]) == nil)
        #expect(V0SettingsReader.scope(environment: ["V0_SCOPE": " \n"]) == nil)
        #expect(V0ProviderDescriptor.descriptor.fetchPlan.sourceModes == [.auto, .api])
    }

    private static func fetch(
        engine: ProviderPluginEngineKind,
        billing: String = Self.tokenBilling,
        rateLimits: String = Self.rateLimits,
        scope: String = "",
        failurePath: String? = nil,
        statusCode: Int = 200,
        errorBody: String = "",
        retryAfter: String = "1") async throws -> UsageSnapshot
    {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            #expect(url.host == "api.v0.dev")
            #expect(url.scheme == "https")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let expectedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(query == (expectedScope.isEmpty ? [] : [URLQueryItem(name: "scope", value: expectedScope)]))
            #expect(["/v1/user/billing", "/v1/rate-limits"].contains(url.path))
            let failed = url.path == failurePath
            let body = failed ? errorBody : url.path == "/v1/user/billing" ? billing : rateLimits
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: failed ? statusCode : 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "Retry-After": retryAfter]))
            return (Data(body.utf8), response)
        }
        let sourceURL = try #require(CodexBarCoreResources.bundle?.url(forResource: "v0", withExtension: "js"))
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let runtime = try ProviderPluginRuntime(source: source, transport: transport, engine: engine)
        return try await runtime.fetchUsage(
            settings: ["V0_SCOPE": scope], secrets: ["V0_API_KEY": "fixture-key"],
            now: Date(timeIntervalSince1970: 1_800_000_000))
    }
}
