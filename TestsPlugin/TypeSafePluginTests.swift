import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct TypeSafePluginTests {
    static let now = Date(timeIntervalSince1970: 1_758_240_000)
    // swiftlint:disable line_length
    private static let body = #"""
    {"billing":{"plan":"free_plan","spent":0.01,"freeCreditsRemaining":4.98,"balance":4.98,"purchased":0,"resetsInDays":12,"cycleLabel":"September 2026","credits":[{"id":"00000000-0000-4000-8000-000000000001","amount":5,"remaining":4.98,"expiresAt":"2026-10-19T00:00:00Z"},{"id":"00000000-0000-4000-8000-000000000002","amount":2,"remaining":0,"expiresAt":"2026-10-19T00:00:00Z"}]},"payments":[],"credits":[],"hasMore":false}
    """#
    // swiftlint:enable line_length
    private static let browserUserAgent =
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Chrome/143.0.0.0 Safari/537.36"

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing maps spend balance plan and active credits`(engine: ProviderPluginEngineKind) async throws {
        let requests = RequestLog()
        let usage = try await Self.fetch(engine: engine) { request in
            await requests.append(request)
            return try await Self.defaultHandler(body: Self.body)(request)
        }

        #expect(usage.providerCost?.used == 0.01)
        #expect(usage.providerCost?.balance == 4.98)
        #expect(usage.providerCost?.currencyCode == "USD")
        #expect(usage.providerCost?.period == "September 2026")
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.identity?.loginMethod == "Balance: $4.98")
        #expect(usage.details.first?.rows.map(\.label) == ["Spent (September 2026)", "Plan", "Credit"])
        #expect(usage.details.first?.rows.dropFirst().first?.value == "Free")
        #expect(usage.details.first?.rows.last?.value.contains("4.98 of 5") == true)

        let recorded = await requests.all
        #expect(recorded.count == 1)
        let request = try #require(recorded.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/billing/overview")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "session=fixture")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing requests carry a browser style user agent`(engine: ProviderPluginEngineKind) async throws {
        let requests = RequestLog()
        _ = try await Self.fetch(engine: engine) { request in
            await requests.append(request)
            return try await Self.defaultHandler(body: Self.body)(request)
        }

        let recorded = await requests.all
        let userAgents = recorded.map { $0.value(forHTTPHeaderField: "User-Agent") ?? "" }
        #expect(userAgents.isEmpty == false)
        // Cloudflare blocks the Linux default UA (it contains "curl/"), so every request sends the browser-style one.
        #expect(userAgents.allSatisfy { !$0.isEmpty && !$0.contains("curl/") } == true)
        #expect(userAgents.allSatisfy { $0 == Self.browserUserAgent } == true)
    }

    @Test(
        arguments: [
            ("null", "4.98"),
            ("4.98", "null"),
            ("\"bad\"", "4.98"),
            ("4.98", "\"bad\""),
        ],
        BundledPluginTestSupport.engines)
    func `missing or malformed billing numbers fail parsing`(
        values: (String, String),
        engine: ProviderPluginEngineKind) async
    {
        let (balance, spent) = values
        let body = Self.body
            .replacingOccurrences(of: "\"balance\":4.98", with: "\"balance\":\(balance)")
            .replacingOccurrences(of: "\"spent\":0.01", with: "\"spent\":\(spent)")
        await Self.expectFailure(.parseFailure, engine: engine, body: body)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing billing object is a parse failure`(engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(.parseFailure, engine: engine, body: #"{"payments":[],"credits":[]}"#)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `invalid json is a parse failure`(engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(.parseFailure, engine: engine, body: "not json")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `login redirect is authentication expiry`(engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(
            .authenticationExpired,
            engine: engine,
            body: "",
            headers: ["Location": "https://console.typesafe.ai/login?next=%2Fbilling"],
            status: 307)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `login landing page is authentication expiry`(engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(
            .authenticationExpired,
            engine: engine,
            body: #"<html><title>TypeSafe</title><body>Sign in to continue</body></html>"#)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `non-login redirect is an api failure`(engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(
            .apiFailure,
            engine: engine,
            body: "",
            headers: ["Location": "https://console.typesafe.ai/billing/"],
            status: 307)
    }

    @Test(arguments: [401, 403], BundledPluginTestSupport.engines)
    func `unauthorized responses are authentication expiry`(
        status: Int, engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(.authenticationExpired, engine: engine, body: "", status: status)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `not found is an api failure`(engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(.apiFailure, engine: engine, body: "", status: 404)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `rate limits retain retry delay`(engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(
            .rateLimited,
            engine: engine,
            body: "",
            headers: ["Retry-After": "30"],
            status: 429,
            expectedRetryAfter: 10)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `server outages are provider unavailable`(engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(.providerUnavailable, engine: engine, body: "", status: 503)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero balance remains zero`(engine: ProviderPluginEngineKind) async throws {
        let body = Self.body.replacingOccurrences(of: #""balance":4.98"#, with: #""balance":0"#)
        let usage = try await Self.fetch(engine: engine, handler: Self.defaultHandler(body: body))
        #expect(usage.providerCost?.balance == 0)
    }

    @Test
    func `descriptor reuses one strategy runtime across refreshes`() async throws {
        let requests = RequestLog()
        let descriptor = TypeSafeProviderDescriptor.makeDescriptor(
            transport: ProviderHTTPTransportHandler { request in
                await requests.append(request)
                return try await Self.defaultHandler(body: Self.body)(request)
            })
        let context = Self.context()
        let first = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        let second = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        #expect(first.count == 1)
        #expect(second.count == 1)
        _ = try await first[0].fetch(context)
        _ = try await second[0].fetch(context)
        let recorded = await requests.all
        #expect(recorded.count == 2)
        #expect(recorded.allSatisfy { $0.url?.path == "/api/billing/overview" })
    }

    @Test(arguments: [22, 23, 24, 300], [false, true])
    func `large credit lists remain within detail limits without changing reported money`(
        count: Int, hasPlan: Bool) async throws
    {
        for engine in BundledPluginTestSupport.engines {
            let credit: [String: Any] = ["amount": 5, "remaining": 4, "expiresAt": "2027-01-01T00:00:00Z"]
            var billing: [String: Any] = [
                "spent": 12.5,
                "balance": 99,
                "credits": Array(repeating: credit, count: count) + [
                    ["amount": 5, "remaining": 0, "expiresAt": "2027-01-01T00:00:00Z"],
                    ["amount": 5, "remaining": 4, "expiresAt": "invalid"],
                ],
            ]
            if hasPlan { billing["plan"] = "free_plan" }
            let json = try JSONSerialization.data(withJSONObject: ["billing": billing])
            let body = try #require(String(data: json, encoding: .utf8))
            let snapshot = try await Self.fetch(engine: engine, handler: Self.defaultHandler(body: body))
            #expect(snapshot.providerCost?.used == 12.5)
            #expect(snapshot.providerCost?.balance == 99)
            let rows = try #require(snapshot.details.first?.rows)
            #expect(rows.count <= 24)
            let slots = hasPlan ? 22 : 23
            if count > slots {
                #expect(rows.last?.label == "Additional credits")
                #expect(rows.last?.value == String(count - slots + 1))
            } else {
                #expect(rows.filter { $0.label == "Credit" }.count == count)
            }
        }
    }

    private static func runtime(
        engine: ProviderPluginEngineKind,
        handler: @escaping Handler) throws -> ProviderPluginRuntime
    {
        try BundledPluginTestSupport.runtime(
            "typesafe",
            engine: engine,
            transport: ProviderHTTPTransportHandler(handler))
    }

    private typealias Handler = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static func fetch(
        engine: ProviderPluginEngineKind,
        handler: @escaping Handler) async throws -> UsageSnapshot
    {
        let runtime = try Self.runtime(engine: engine, handler: handler)
        return try await Self.fetch(runtime: runtime)
    }

    static func fetch(engine: ProviderPluginEngineKind) async throws -> UsageSnapshot {
        try await self.fetch(engine: engine, handler: self.defaultHandler(body: self.body))
    }

    private static func fetch(runtime: ProviderPluginRuntime) async throws -> UsageSnapshot {
        try await runtime.fetchUsage(now: self.now, cookieResolver: { _, domain in
            #expect(domain == "typesafe.ai")
            return "session=fixture"
        })
    }

    private static func context() -> ProviderFetchContext {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .web,
            includeCredits: false,
            webTimeout: 20,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: .make(typesafe: TypeSafeProviderSettings(
                cookieSource: .manual,
                manualCookieHeader: "session=fixture")),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: TypeSafePluginClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    private static func expectFailure(
        _ kind: ProviderFetchClassifiedError.Kind,
        engine: ProviderPluginEngineKind,
        body: String = "",
        headers: [String: String] = [:],
        status: Int = 200,
        expectedRetryAfter: Int? = nil) async
    {
        do {
            _ = try await self.fetch(
                engine: engine,
                handler: self.defaultHandler(body: body, headers: headers, status: status))
            Issue.record("Expected \(kind.rawValue) failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            if let expectedRetryAfter {
                #expect(error.retryAfterSeconds == TimeInterval(expectedRetryAfter))
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static func defaultHandler(
        body: String,
        headers: [String: String] = [:],
        status: Int = 200) -> Handler
    {
        { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/billing/overview"):
                try Self.response(request, status: status, headers: headers, body: body)
            default:
                try Self.response(request, status: 404, body: "not found")
            }
        }
    }

    private static func response(
        _ request: URLRequest,
        status: Int = 200,
        headers: [String: String] = [:],
        body: String,
        contentType: String = "application/json") throws -> (Data, URLResponse)
    {
        let url = try #require(request.url)
        var responseHeaders = headers
        responseHeaders["Content-Type"] = contentType
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: responseHeaders))
        return (Data(body.utf8), response)
    }
}

private actor RequestLog {
    private(set) var all: [URLRequest] = []

    func append(_ request: URLRequest) {
        self.all.append(request)
    }
}

private struct TypeSafePluginClaudeFetcher: ClaudeUsageFetching {
    func detectVersion() -> String? { nil }

    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ProviderPluginError.script("unused")
    }

    func debugRawProbe(model _: String) async -> String {
        "unused"
    }
}
