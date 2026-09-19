import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ReplicatePluginTests {
    static let now = Date(timeIntervalSince1970: 1_755_000_000)
    static let invoices = #"""
    {"invoices":[{"type":"monthly-usage",
    "ended_before":null,
    "total_cost_before_adjustments":"12.40",
    "total_cost":"0"}]}
    """#
    static let html = #"""
    <script type="application/json" id="react-component-props-billing-page">
    {"page":{"account":{"kind":"user","username":"demo-user"}}}
    </script>
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing publishes spend and optional credit without invented quota`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(engine: engine)
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.providerCost?.used == 12.4)
        #expect(usage.providerCost?.balance == 80)
        #expect(usage.identity?.accountID == "demo-user")
        #expect(usage.identity?.accountOrganization == nil)
        #expect(usage.details.first?.rows.map(\.value) == ["$12.40", "$80.00"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `nested organization props choose only the organization account path`(
        engine: ProviderPluginEngineKind) async throws
    {
        let html = #"""
        <script id='react-component-props-layout' type='application/json'>
        {"layout":{"nested":{"account":{"kind":"organization","username":"demo-org"}}}}
        </script>
        """#
        let usage = try await Self.fetch(html: html, accountPath: "organizations/demo-org", engine: engine)
        #expect(usage.identity?.accountOrganization == "demo-org")
    }

    @Test(
        arguments: ["null", "\"\"", "\"NaN\"", "\"Infinity\"", "\"-1\"", "12", "true"],
        BundledPluginTestSupport.engines)
    func `invalid required spend never becomes zero`(value: String, engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(.parseFailure) {
            try await Self.fetch(
                invoices: Self.invoices.replacingOccurrences(of: "\"12.40\"", with: value),
                engine: engine)
        }
    }

    @Test(
        arguments: [
            "{}",
            "{\"unused_credit\":\"NaN\"}",
            "{\"unused_credit\":\"Infinity\"}",
            "<html>unavailable</html>"
        ],
        BundledPluginTestSupport.engines)
    func `optional malformed credit preserves spend`(credit: String, engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(credit: credit, engine: engine)
        #expect(usage.providerCost?.used == 12.4)
        #expect(usage.providerCost?.balance == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `optional request failure preserves zero spend`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(
            invoices: Self.invoices.replacingOccurrences(of: "12.40", with: "0"),
            creditStatus: 503,
            engine: engine)
        #expect(usage.providerCost?.used == 0)
        #expect(usage.providerCost?.balance == nil)
    }

    @Test(
        arguments: [
            "<html>Sign in</html>",
            #"""
            <script type="application/json" id="other">
            {"account":{"kind":"user","username":"wrong"}}</script>
            """#,
        ],
        BundledPluginTestSupport.engines)
    func `unrecognized HTML preserves the selected credential`(html: String, engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(.parseFailure) { try await Self.fetch(html: html, engine: engine) }
    }

    @Test(
        arguments: [(401, ProviderFetchClassifiedError.Kind.authenticationExpired), (429, .rateLimited), (
            503,
            .providerUnavailable)],
        BundledPluginTestSupport.engines)
    func `HTTP failures are classified before decoding`(
        failure: (Int, ProviderFetchClassifiedError.Kind),
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(failure.1) {
            try await Self.fetch(invoices: "<html>error</html>", invoiceStatus: failure.0, engine: engine)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `expired invoices cannot displace current spend`(engine: ProviderPluginEngineKind) async throws {
        let invoices = #"""
        {"invoices":[{"type":"monthly-usage",
        "ended_before":"2020-01-01",
        "total_cost_before_adjustments":"900"},{"type":"monthly-usage",
        "ended_before":"2090-01-01",
        "total_cost_before_adjustments":"12.40"}]}
        """#
        #expect(try await Self.fetch(invoices: invoices, engine: engine).providerCost?.used == 12.4)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `user response policy continues forcing JSON Accept`(engine: ProviderPluginEngineKind) async throws {
        let source = #"""
        defineProvider({id:"replicate",name:"Replicate",endpoints:["https://replicate.com"],settings:[],
          async fetchUsage(ctx) {
            await ctx.http.get("https://replicate.com/api/test", {headers:{Accept:"text/html"}});
            return {cost:{used:1,currency:"USD"}};
          }});
        """#
        let runtime = try ProviderPluginRuntime(
            source: source,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
                return try Self.response(request, body: "{}")
            },
            enforcesUserResponsePolicy: true,
            engine: engine)
        _ = try await runtime.fetchUsage()
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `verified sign in markup permits credential recovery`(engine: ProviderPluginEngineKind) async {
        let html = #"""
        <title>
        Sign in | Replicate</title>
        <a href="/login/github/?next=/account/billing">
        Sign in with GitHub</a>
        """#
        await Self.expectFailure(.authenticationExpired) { try await Self.fetch(html: html, engine: engine) }
    }

    @Test(arguments: [408, 429], BundledPluginTestSupport.engines)
    func `transient responses retain bounded Retry After`(status: Int, engine: ProviderPluginEngineKind) async {
        do {
            _ = try await Self.fetch(invoiceStatus: status, invoiceRetryAfter: "8", engine: engine)
            Issue.record("Expected transient failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.retryAfterSeconds == 8)
            #expect(error.kind == (status == 429 ? .rateLimited : .providerUnavailable))
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    static func fetch(
        html: String = Self.html,
        invoices: String = Self.invoices,
        credit: String = #"{"unused_credit":"80.0"}"#,
        invoiceStatus: Int = 200,
        invoiceRetryAfter: String? = nil,
        creditStatus: Int = 200,
        accountPath: String = "users/demo-user",
        engine: ProviderPluginEngineKind) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "replicate",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.value(forHTTPHeaderField: "Cookie") == "sessionid=synthetic")
                #expect(request.httpMethod == "GET")
                switch request.url?.path {
                case "/account/billing":
                    #expect(request.value(forHTTPHeaderField: "Accept") == "text/html")
                    return try Self.response(request, body: html, contentType: "text/html")
                case "/api/\(accountPath)/invoices":
                    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
                    return try Self.response(
                        request,
                        body: invoices,
                        status: invoiceStatus,
                        retryAfter: invoiceRetryAfter)
                case "/api/\(accountPath)/unused-credit":
                    return try Self.response(request, body: credit, status: creditStatus)
                default:
                    Issue.record("Unexpected request route")
                    return try Self.response(request, body: "{}", status: 404)
                }
            })
        return try await runtime.fetchUsage(now: Self.now, cookieResolver: { provider, domain in
            #expect(provider == .replicate)
            #expect(domain == "replicate.com")
            return "sessionid=synthetic"
        })
    }

    private static func response(
        _ request: URLRequest,
        body: String,
        status: Int = 200,
        contentType: String = "application/json",
        retryAfter: String? = nil) throws -> (Data, URLResponse)
    {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType, "Retry-After": retryAfter ?? ""]))
        return (Data(body.utf8), response)
    }

    private static func expectFailure(
        _ kind: ProviderFetchClassifiedError.Kind,
        operation: () async throws -> UsageSnapshot) async
    {
        do {
            _ = try await operation()
            Issue.record("Expected failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
