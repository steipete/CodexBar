import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct TypeSafeCookieStrategyTests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func append(_ entry: String) { self.lock.withLock { self.entries.append(entry) } }
        var values: [String] {
            self.lock.withLock { self.entries }
        }
    }

    @Test
    func `production transport never reads or stores ambient cookies`() {
        let configuration = TypeSafeWebFetchStrategy.makeConfiguration()

        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
    }

    @Test
    func `cookie records are limited to the billing destination`() {
        let records = [
            Self.record("console.typesafe.ai", scope: .hostOnly, name: "host-console"),
            Self.record("typesafe.ai", scope: .domain, name: "domain-root"),
            Self.record(".typesafe.ai", scope: .domain, name: "dotted-root"),
            Self.record(".console.typesafe.ai", scope: .domain, name: "domain-console"),
            Self.record("CONSOLE.TYPESAFE.AI", scope: .hostOnly, name: "uppercase-host"),
            Self.record("TYPESAFE.AI", scope: .domain, name: "case-insensitive"),
            Self.record("nottypesafe.ai", scope: .domain, name: "lookalike"),
            Self.record("typesafe.ai.example.org", scope: .domain, name: "suffix-lookalike"),
            Self.record("typesafe.ai", scope: .hostOnly, name: "host-root"),
            Self.record("www.typesafe.ai", scope: .hostOnly, name: "host-www"),
            Self.record(".www.typesafe.ai", scope: .domain, name: "domain-www"),
        ]

        let filtered = TypeSafeCookieImporter.recordsForDestination(records)
        #expect(filtered.map(\.name) == [
            "host-console", "domain-root", "dotted-root", "domain-console", "uppercase-host", "case-insensitive",
        ])
        #expect(TypeSafeCookieImporter.cookieHeader(from: records) ==
            "host-console=value; domain-root=value; dotted-root=value; domain-console=value; " +
            "uppercase-host=value; case-insensitive=value")
    }

    @Test
    func `cookie query is exact and Chrome only by default`() {
        let now = Date(timeIntervalSince1970: 1_758_240_000)
        let query = TypeSafeCookieImporter.cookieQuery(referenceDate: now)

        #expect(query.domains == ["console.typesafe.ai", "typesafe.ai"])
        if case .exact = query.domainMatch {} else { Issue.record("expected exact domain matching") }
        #expect(!query.includeExpired)
        #expect(query.referenceDate == now)
        #expect(TypeSafeCookieImporter.resolvedImportOrder(nil) == [.chrome])
        #expect(TypeSafeCookieImporter.resolvedImportOrder([]) == [.chrome])
        #expect(TypeSafeCookieImporter.resolvedImportOrder([.safari]) == [.safari])
    }

    @Test
    func `real plugin sends filtered cookies only to billing requests`() async throws {
        let requests = RequestLog()
        let records = [
            Self.record("console.typesafe.ai", scope: .hostOnly, name: "session", value: "allowed"),
            Self.record(".typesafe.ai", scope: .domain, name: "shared", value: "allowed"),
            Self.record(".console.typesafe.ai", scope: .domain, name: "console", value: "allowed"),
            Self.record(".www.typesafe.ai", scope: .domain, name: "private", value: "blocked"),
            Self.record("nottypesafe.ai", scope: .domain, name: "lookalike", value: "blocked"),
            Self.record("typesafe.ai.example.org", scope: .domain, name: "suffix", value: "blocked"),
            Self.record("typesafe.ai", scope: .hostOnly, name: "root", value: "blocked"),
            Self.record("www.typesafe.ai", scope: .hostOnly, name: "sibling", value: "blocked"),
        ]
        let header = TypeSafeCookieImporter.cookieHeader(from: records)
        let strategy = TypeSafeWebFetchStrategy(
            transport: ProviderHTTPTransportHandler { request in
                await requests.append(request)
                return try Self.pluginResponse(for: request)
            },
            sessionLoader: { _ in [.init(cookieHeader: header, sourceLabel: "Chrome")] },
            cacheLoader: { .authoritative(nil) },
            cacheClearer: { _ in Issue.record("unexpected cache clear"); return false },
            cacheWriter: { _, _ in })

        let result = try await strategy.fetch(Self.context(.auto))

        #expect(result.sourceLabel == "web")
        #expect(result.strategyID == "typesafe.web")
        let recorded = await requests.all
        let billing = try #require(recorded.first { $0.httpMethod == "GET" && $0.url?.path == "/settings/billing" })
        let chunk = try #require(recorded.first { $0.url?.path == "/_next/static/chunks/app.js" })
        let post = try #require(recorded.first { $0.httpMethod == "POST" })
        #expect(billing.value(forHTTPHeaderField: "Cookie") == "session=allowed; shared=allowed; console=allowed")
        #expect(post.value(forHTTPHeaderField: "Cookie") == "session=allowed; shared=allowed; console=allowed")
        #expect(chunk.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test
    func `manual cookie bypasses cache and browser import`() async throws {
        let log = Log()
        let strategy = TypeSafeWebFetchStrategy(
            usageLoader: { cookie in log.append(cookie); return Self.usage() },
            sessionLoader: { _ in Issue.record("unexpected import"); return [] },
            cacheLoader: { Issue.record("unexpected cache read"); return .authoritative(nil) },
            cacheClearer: { _ in Issue.record("unexpected cache clear"); return false },
            cacheWriter: { _, _ in Issue.record("unexpected cache write") })

        _ = try await strategy.fetch(Self.context(.manual, header: " Cookie: arbitrary=value "))
        #expect(log.values == ["arbitrary=value"])
    }

    @Test
    func `authentication failure clears observed cache and stores winning candidate`() async throws {
        let log = Log()
        let cached = CookieHeaderCache.Entry(
            cookieHeader: "session=stale",
            storedAt: TypeSafePluginTests.now,
            sourceLabel: "old")
        let strategy = TypeSafeWebFetchStrategy(
            usageLoader: { cookie in
                log.append(cookie)
                guard cookie == "session=valid" else {
                    throw ProviderFetchClassifiedError(kind: .authenticationExpired, message: "fixture")
                }
                return Self.usage()
            },
            sessionLoader: { _ in [
                .init(cookieHeader: "session=expired", sourceLabel: "Chrome A"),
                .init(cookieHeader: "session=valid", sourceLabel: "Chrome B"),
            ] },
            cacheLoader: { .authoritative(cached) },
            cacheClearer: { expected in #expect(expected == cached); return true },
            cacheWriter: { expected, session in
                #expect(expected.entry == nil)
                #expect(session.sourceLabel == "Chrome B")
                log.append("stored")
            })

        _ = try await strategy.fetch(Self.context(.auto))
        #expect(log.values == ["session=stale", "session=expired", "session=valid", "stored"])
    }

    @Test
    func `real plugin recovers a rejected cached session from the browser`() async throws {
        let requests = RequestLog()
        let log = Log()
        let cached = CookieHeaderCache.Entry(
            cookieHeader: "session=stale",
            storedAt: TypeSafePluginTests.now,
            sourceLabel: "old")
        let strategy = TypeSafeWebFetchStrategy(
            transport: ProviderHTTPTransportHandler { request in
                await requests.append(request)
                if request.value(forHTTPHeaderField: "Cookie") == "session=stale" {
                    return try Self.response(request, status: 307, body: "", contentType: "text/html")
                }
                return try Self.pluginResponse(for: request)
            },
            sessionLoader: { _ in [.init(cookieHeader: "session=fresh", sourceLabel: "Chrome")] },
            cacheLoader: { .authoritative(cached) },
            cacheClearer: { expected in #expect(expected == cached); log.append("cleared"); return true },
            cacheWriter: { expected, session in
                #expect(expected.entry == nil)
                log.append("stored \(session.cookieHeader)")
            })

        let result = try await strategy.fetch(Self.context(.auto))

        #expect(result.usage.providerCost?.balance == 4.98)
        #expect(log.values == ["cleared", "stored session=fresh"])
        let cookies = await requests.all.filter { $0.httpMethod != nil && $0.url?.path == "/settings/billing" }
            .map { $0.value(forHTTPHeaderField: "Cookie") }
        #expect(cookies == ["session=stale", "session=fresh", "session=fresh"])
    }

    @Test(arguments: [ProviderFetchClassifiedError.Kind.networkFailure, .parseFailure, .rateLimited])
    func `non authentication failures preserve cache without importing`(kind: ProviderFetchClassifiedError.Kind) async {
        let error = ProviderFetchClassifiedError(kind: kind, message: "fixture")
        let strategy = TypeSafeWebFetchStrategy(
            usageLoader: { _ in throw error },
            sessionLoader: { _ in Issue.record("unexpected import"); return [] },
            cacheLoader: { .authoritative(.init(
                cookieHeader: "session=cached",
                storedAt: TypeSafePluginTests.now,
                sourceLabel: "Chrome")) },
            cacheClearer: { _ in Issue.record("unexpected clear"); return false },
            cacheWriter: { _, _ in Issue.record("unexpected write") })

        await #expect(throws: error) { try await strategy.fetch(Self.context(.auto)) }
    }

    @Test
    func `temporarily unavailable cache stops before browser import`() async {
        let strategy = TypeSafeWebFetchStrategy(
            usageLoader: { _ in Issue.record("unexpected fetch"); return Self.usage() },
            sessionLoader: { _ in Issue.record("unexpected import"); return [] },
            cacheLoader: { .keychainTemporarilyUnavailable(legacyEntry: nil) },
            cacheClearer: { _ in Issue.record("unexpected clear"); return false },
            cacheWriter: { _, _ in Issue.record("unexpected write") })

        await #expect(throws: TypeSafeCredentialError.cacheUnavailable) {
            try await strategy.fetch(Self.context(.auto))
        }
    }

    @Test
    func `pinned cached account never falls back`() async {
        let error = ProviderFetchClassifiedError(kind: .authenticationExpired, message: "fixture")
        let strategy = TypeSafeWebFetchStrategy(
            usageLoader: { _ in throw error },
            sessionLoader: { _ in Issue.record("unexpected fallback"); return [] },
            cacheLoader: { .authoritative(.init(
                cookieHeader: "session=pinned",
                storedAt: TypeSafePluginTests.now,
                sourceLabel: "pinned",
                authenticationFailurePolicy: .stopFallback)) },
            cacheClearer: { _ in Issue.record("unexpected clear"); return false },
            cacheWriter: { _, _ in Issue.record("unexpected write") })

        await #expect(throws: error) { try await strategy.fetch(Self.context(.auto)) }
    }

    @Test
    func `concurrent cache replacement is not overwritten`() async throws {
        let cached = CookieHeaderCache.Entry(
            cookieHeader: "session=old",
            storedAt: TypeSafePluginTests.now,
            sourceLabel: "old")
        let strategy = TypeSafeWebFetchStrategy(
            usageLoader: { header in
                if header == cached.cookieHeader {
                    throw ProviderFetchClassifiedError(kind: .authenticationExpired, message: "fixture")
                }
                return Self.usage()
            },
            sessionLoader: { _ in [.init(cookieHeader: "session=new", sourceLabel: "new")] },
            cacheLoader: { .authoritative(cached) },
            cacheClearer: { _ in false },
            cacheWriter: { expected, _ in #expect(expected.entry == cached) })

        _ = try await strategy.fetch(Self.context(.auto))
    }

    @Test
    func `cancellation cannot publish candidate to cache`() async {
        let strategy = TypeSafeWebFetchStrategy(
            usageLoader: { _ in withUnsafeCurrentTask { $0?.cancel() }; return Self.usage() },
            sessionLoader: { _ in [.init(cookieHeader: "session=fixture", sourceLabel: "Chrome")] },
            cacheLoader: { .authoritative(nil) },
            cacheClearer: { _ in Issue.record("unexpected clear"); return false },
            cacheWriter: { _, _ in Issue.record("cancelled cache write") })
        let task = Task { try await strategy.fetch(Self.context(.auto)) }

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private static let actionID = String(repeating: "b", count: 40)
    private static let html = #"<script src="/_next/static/chunks/app.js"></script>"#
    private static let chunk = "\"" + Self.actionID
        + "\",c.callServer,void 0,c.findSourceMapURL,\"getBillingOverviewResult\""
    // swiftlint:disable line_length
    private static let body = #"""
    0:{"a":"$@1"}
    1:{"ok":true,"data":{"billing":{"plan":"free_plan","spent":0.01,"freeCreditsRemaining":4.98,"balance":4.98,"purchased":0,"resetsInDays":12,"cycleLabel":"September 2026","credits":[]}}}
    """#
    // swiftlint:enable line_length

    private static func record(
        _ domain: String,
        scope: BrowserCookieScope,
        name: String,
        value: String = "value") -> BrowserCookieRecord
    {
        BrowserCookieRecord(
            domain: domain,
            name: name,
            path: "/",
            value: value,
            expires: nil,
            isSecure: true,
            isHTTPOnly: true,
            scope: scope)
    }

    private static func pluginResponse(for request: URLRequest) throws -> (Data, URLResponse) {
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/settings/billing"):
            try self.response(request, body: self.html, contentType: "text/html")
        case ("GET", "/_next/static/chunks/app.js"):
            try self.response(request, body: self.chunk, contentType: "application/javascript")
        case ("POST", "/settings/billing"):
            try self.response(request, body: self.body, contentType: "text/x-component")
        default:
            try self.response(request, status: 404, body: "not found")
        }
    }

    private static func response(
        _ request: URLRequest,
        status: Int = 200,
        body: String,
        contentType: String = "application/json") throws -> (Data, URLResponse)
    {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]))
        return (Data(body.utf8), response)
    }

    private static func usage() -> UsageSnapshot {
        UsageSnapshot(primary: nil, secondary: nil, updatedAt: TypeSafePluginTests.now)
    }

    private static func context(_ source: ProviderCookieSource, header: String? = nil) -> ProviderFetchContext {
        let browser = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .web,
            includeCredits: false,
            webTimeout: 20,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: .make(typesafe: .init(cookieSource: source, manualCookieHeader: header)),
            fetcher: UsageFetcher(),
            claudeFetcher: TypeSafeCookieStrategyClaudeFetcher(),
            browserDetection: browser)
    }
}

private actor RequestLog {
    private(set) var all: [URLRequest] = []

    func append(_ request: URLRequest) {
        self.all.append(request)
    }
}

private struct TypeSafeCookieStrategyClaudeFetcher: ClaudeUsageFetching {
    func detectVersion() -> String? { nil }
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ProviderPluginError.script("unused")
    }

    func debugRawProbe(model _: String) async -> String { "unused" }
}
#endif
