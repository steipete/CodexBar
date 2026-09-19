import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct TypeSafePluginTests {
    private static let oldActionID = String(repeating: "a", count: 40)
    private static let freshActionID = String(repeating: "b", count: 40)
    static let now = Date(timeIntervalSince1970: 1_758_240_000)
    private static let html = #"<script src="/_next/static/chunks/app.js"></script>"#
    private static let chunk = "\"" + Self.freshActionID
        + "\",c.callServer,void 0,c.findSourceMapURL,\"getBillingOverviewResult\""
    // swiftlint:disable line_length
    private static let body = #"""
    0:{"a":"$@1"}
    1:{"ok":true,"data":{"billing":{"plan":"free_plan","spent":0.01,"freeCreditsRemaining":4.98,"balance":4.98,"purchased":0,"resetsInDays":12,"cycleLabel":"September 2026","credits":[{"id":"00000000-0000-4000-8000-000000000001","amount":5,"remaining":4.98,"expiresAt":"2026-10-19T00:00:00Z"},{"id":"00000000-0000-4000-8000-000000000002","amount":2,"remaining":0,"expiresAt":"2026-10-19T00:00:00Z"}]}}}
    """#
    // swiftlint:enable line_length

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing maps spend balance plan and active credits`(engine: ProviderPluginEngineKind) async throws {
        let requests = RequestLog()
        let usage = try await Self.fetch(engine: engine) { request in
            await requests.append(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/settings/billing"):
                return try Self.response(request, body: Self.html, contentType: "text/html")
            case ("GET", "/_next/static/chunks/app.js"):
                return try Self.response(request, body: Self.chunk, contentType: "application/javascript")
            case ("POST", "/settings/billing"):
                return try Self.response(request, body: Self.body, contentType: "text/x-component")
            default:
                return try Self.response(request, status: 404, body: "not found")
            }
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
        let post = try #require(recorded.first { $0.httpMethod == "POST" })
        #expect(post.value(forHTTPHeaderField: "Cookie") == "session=fixture")
        #expect(post.value(forHTTPHeaderField: "Origin") == "https://console.typesafe.ai")
        #expect(post.value(forHTTPHeaderField: "Next-Action") == Self.freshActionID)
        #expect(post.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(post.httpBody == Data("[]".utf8))
        #expect(recorded.filter { $0.url?.path == "/_next/static/chunks/app.js" }.count == 1)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `second fetch reuses action id without rescanning chunks`(engine: ProviderPluginEngineKind) async throws {
        let requests = RequestLog()
        let runtime = try Self.runtime(engine: engine) { request in
            await requests.append(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/settings/billing"):
                return try Self.response(request, body: Self.html, contentType: "text/html")
            case ("GET", "/_next/static/chunks/app.js"):
                return try Self.response(request, body: Self.chunk, contentType: "application/javascript")
            case ("POST", "/settings/billing"):
                return try Self.response(request, body: Self.body, contentType: "text/x-component")
            default:
                return try Self.response(request, status: 404, body: "not found")
            }
        }

        _ = try await Self.fetch(runtime: runtime)
        _ = try await Self.fetch(runtime: runtime)

        let recorded = await requests.all
        #expect(recorded.filter { $0.url?.path == "/_next/static/chunks/app.js" }.count == 1)
        #expect(recorded.filter { $0.httpMethod == "POST" }.count == 2)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `stale action id triggers one rediscovery and one retry`(engine: ProviderPluginEngineKind) async throws {
        let requests = RequestLog()
        let pages = RequestCounter()
        let runtime = try Self.runtime(engine: engine) { request in
            await requests.append(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/settings/billing"):
                let page = await pages.next() == 1 ? Self.html : Self.html
                return try Self.response(request, body: page, contentType: "text/html")
            case ("GET", "/_next/static/chunks/app.js"):
                let actionID = await pages.value == 1 ? Self.oldActionID : Self.freshActionID
                let chunk = "\"" + actionID + "\",c.callServer,void 0,c.findSourceMapURL,\"getBillingOverviewResult\""
                return try Self.response(request, body: chunk, contentType: "application/javascript")
            case ("POST", "/settings/billing"):
                if request.value(forHTTPHeaderField: "Next-Action") == Self.oldActionID {
                    return try Self.response(
                        request,
                        status: 404,
                        headers: ["x-nextjs-action-not-found": "1"],
                        body: "Server action not found.")
                }
                return try Self.response(request, body: Self.body, contentType: "text/x-component")
            default:
                return try Self.response(request, status: 404, body: "not found")
            }
        }

        _ = try await Self.fetch(runtime: runtime)

        let recorded = await requests.all
        #expect(recorded.filter { $0.url?.path == "/settings/billing" && $0.httpMethod == "GET" }.count == 2)
        #expect(recorded.filter { $0.url?.path == "/_next/static/chunks/app.js" }.count == 2)
        #expect(recorded.filter { $0.httpMethod == "POST" }.map { $0.value(forHTTPHeaderField: "Next-Action") } == [
            Self.oldActionID,
            Self.freshActionID,
        ])
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
    func `ok false is an api failure`(engine: ProviderPluginEngineKind) async {
        let body = Self.body.replacingOccurrences(of: #""ok":true"#, with: #""ok":false"#)
        await Self.expectFailure(.apiFailure, engine: engine, body: body)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `login redirect and landing are authentication expiry`(engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(.authenticationExpired, engine: engine, html: "", status: 307)
        await Self.expectFailure(
            .authenticationExpired,
            engine: engine,
            // swiftlint:disable:next line_length
            html: #"<html><title>TypeSafe</title><script>self.__next_f.push([1,"0:{\"f\":[[[\"\",{\"children\":[\"(auth)\",{\"children\":[\"login\",{\"children\":[\"__PAGE__\",{}]}]}]}]]}"])</script></html>"#)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `action id missing from chunks is a parse failure`(engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(
            .parseFailure,
            engine: engine,
            chunk: "console.log('fixture')")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero balance remains zero`(engine: ProviderPluginEngineKind) async throws {
        let body = Self.body.replacingOccurrences(of: #""balance":4.98"#, with: #""balance":0"#)
        let usage = try await Self.fetch(
            engine: engine,
            handler: Self.defaultHandler(html: Self.html, chunk: Self.chunk, body: body))
        #expect(usage.providerCost?.balance == 0)
    }

    @Test
    func `descriptor reuses one strategy runtime across refreshes`() async throws {
        let requests = RequestLog()
        let descriptor = TypeSafeProviderDescriptor.makeDescriptor(
            transport: ProviderHTTPTransportHandler { request in
                await requests.append(request)
                return try await Self.defaultHandler(html: Self.html, chunk: Self.chunk, body: Self.body)(request)
            })
        let context = Self.context()
        let first = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        let second = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        #expect(first.count == 1)
        #expect(second.count == 1)
        _ = try await first[0].fetch(context)
        _ = try await second[0].fetch(context)
        let recorded = await requests.all
        #expect(recorded.filter { $0.url?.path == "/_next/static/chunks/app.js" }.count == 1)
        #expect(recorded.filter { $0.httpMethod == "POST" }.count == 2)
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
        try await self.fetch(
            engine: engine,
            handler: self.defaultHandler(html: self.html, chunk: self.chunk, body: self.body))
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
        html: String = Self.html,
        chunk: String = Self.chunk,
        body: String = Self.body,
        status: Int = 200) async
    {
        do {
            _ = try await self.fetch(
                engine: engine,
                handler: self.defaultHandler(html: html, chunk: chunk, body: body, status: status))
            Issue.record("Expected \(kind.rawValue) failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static func defaultHandler(
        html: String,
        chunk: String,
        body: String,
        status: Int = 200) -> Handler
    {
        { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/settings/billing"):
                try Self.response(request, status: status, body: html, contentType: "text/html")
            case ("GET", "/_next/static/chunks/app.js"):
                try Self.response(request, body: chunk, contentType: "application/javascript")
            case ("POST", "/settings/billing"):
                try Self.response(request, body: body, contentType: "text/x-component")
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

private actor RequestCounter {
    private(set) var value = 0

    func next() -> Int {
        self.value += 1
        return self.value
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
