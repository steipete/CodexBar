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
    func `cookie query is exact and follows the shared browser order by default`() {
        let now = Date(timeIntervalSince1970: 1_758_240_000)
        let query = TypeSafeCookieImporter.cookieQuery(referenceDate: now)

        #expect(query.domains == ["console.typesafe.ai", "typesafe.ai"])
        if case .exact = query.domainMatch {} else { Issue.record("expected exact domain matching") }
        #expect(!query.includeExpired)
        #expect(query.referenceDate == now)
        #expect(ProviderDefaults.metadata[.typesafe]?.browserCookieOrder == Browser.defaultImportOrder)
        #expect(TypeSafeCookieImporter.resolvedImportOrder(nil) == Browser.defaultImportOrder)
        #expect(TypeSafeCookieImporter.resolvedImportOrder([]) == Browser.defaultImportOrder)
        #expect(TypeSafeCookieImporter.resolvedImportOrder([.safari]) == [.safari])
    }

    @Test
    func `cookie paths match billing overview and preserve longest path precedence`() {
        let records = [
            Self.record("console.typesafe.ai", scope: .hostOnly, name: "session", value: "root"),
            Self.record(
                "console.typesafe.ai",
                scope: .hostOnly,
                name: "session",
                value: "overview",
                path: "/api/billing/overview"),
            Self.record(
                "console.typesafe.ai",
                scope: .hostOnly,
                name: "billing-api",
                value: "value",
                path: "/api/billing"),
            Self.record(
                "console.typesafe.ai",
                scope: .hostOnly,
                name: "trailing",
                path: "/api/billing/overview/"),
            Self.record(
                "console.typesafe.ai",
                scope: .hostOnly,
                name: "sibling",
                path: "/api/billing/overview-extra"),
            Self.record("console.typesafe.ai", scope: .hostOnly, name: "legacy", path: "/billing"),
            Self.record("console.typesafe.ai", scope: .hostOnly, name: "auth", path: "/auth"),
        ]
        let filtered = TypeSafeCookieImporter.recordsForDestination(records)
        #expect(filtered.map(\.name) == ["session", "billing-api", "session"])
        #expect(TypeSafeCookieImporter.cookieHeader(from: records) ==
            "session=overview; billing-api=value; session=root")
    }

    @Test
    func `legacy unscoped cache is excluded from the billing request`() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        try await KeychainCacheStore.withImplicitTestStoreForTesting {
            try await CookieHeaderCache.withLegacyBaseURLOverrideForTesting(storage) {
                CookieHeaderCache.store(
                    provider: .typesafe,
                    cookieHeader: "session=legacy-settings",
                    sourceLabel: "legacy")
                defer { CookieHeaderCache.clearAllScopes(provider: .typesafe) }

                let requests = RequestLog()
                let strategy = TypeSafeWebFetchStrategy(
                    transport: ProviderHTTPTransportHandler { request in
                        await requests.append(request)
                        return try TypeSafeTestFixture.pluginResponse(for: request)
                    },
                    sessionLoader: { _ in
                        AnySequence([.init(cookieHeader: "session=fresh-billing", sourceLabel: "Chrome")])
                    })

                _ = try await strategy.fetch(Self.context(.auto))

                let recorded = await requests.all
                let billingRequests = recorded.filter { $0.url?.path == "/api/billing/overview" }
                #expect(!billingRequests.isEmpty)
                #expect(billingRequests.allSatisfy {
                    $0.value(forHTTPHeaderField: "Cookie") == "session=fresh-billing"
                })
                #expect(CookieHeaderCache.load(provider: .typesafe)?.cookieHeader == "session=legacy-settings")
                #expect(CookieHeaderCache.load(
                    provider: .typesafe,
                    scope: .typesafeBilling)?.cookieHeader == "session=fresh-billing")
            }
        }
    }

    @Test
    func `real plugin sends filtered cookies only to the billing overview request`() async throws {
        let requests = RequestLog()
        let records = [
            Self.record("console.typesafe.ai", scope: .hostOnly, name: "session", value: "allowed"),
            Self.record(".typesafe.ai", scope: .domain, name: "shared", value: "allowed"),
            Self.record(".console.typesafe.ai", scope: .domain, name: "console", value: "allowed"),
            Self.record(
                "console.typesafe.ai",
                scope: .hostOnly,
                name: "scoped",
                value: "allowed",
                path: "/api/billing/overview"),
            Self.record("console.typesafe.ai", scope: .hostOnly, name: "legacy", value: "blocked", path: "/billing"),
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
                return try TypeSafeTestFixture.pluginResponse(for: request)
            },
            sessionLoader: { _ in AnySequence([.init(cookieHeader: header, sourceLabel: "Chrome")]) },
            cacheLoader: { .authoritative(nil) },
            cacheClearer: { _ in Issue.record("unexpected cache clear"); return false },
            cacheWriter: { _, _ in })

        let result = try await strategy.fetch(Self.context(.auto))

        #expect(result.sourceLabel == "web")
        #expect(result.strategyID == "typesafe.web")
        let recorded = await requests.all
        #expect(recorded.count == 1)
        let overview = try #require(recorded
            .first { $0.httpMethod == "GET" && $0.url?.path == "/api/billing/overview" })
        #expect(overview.value(forHTTPHeaderField: "Cookie") ==
            "scoped=allowed; session=allowed; shared=allowed; console=allowed")
    }

    @Test
    func `manual cookie bypasses cache and browser import`() async throws {
        let log = Log()
        let strategy = TypeSafeWebFetchStrategy(
            usageLoader: { cookie in log.append(cookie); return Self.usage() },
            sessionLoader: { _ in Issue.record("unexpected import"); return AnySequence([]) },
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
            storedAt: TypeSafeTestFixture.now,
            sourceLabel: "old")
        let strategy = TypeSafeWebFetchStrategy(
            usageLoader: { cookie in
                log.append(cookie)
                guard cookie == "session=valid" else {
                    throw ProviderFetchClassifiedError(kind: .authenticationExpired, message: "fixture")
                }
                return Self.usage()
            },
            sessionLoader: { _ in AnySequence([
                .init(cookieHeader: "session=expired", sourceLabel: "Chrome A"),
                .init(cookieHeader: "session=valid", sourceLabel: "Chrome B"),
            ]) },
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
            storedAt: TypeSafeTestFixture.now,
            sourceLabel: "old")
        let strategy = TypeSafeWebFetchStrategy(
            transport: ProviderHTTPTransportHandler { request in
                await requests.append(request)
                if request.value(forHTTPHeaderField: "Cookie") == "session=stale" {
                    return try TypeSafeTestFixture.response(
                        request,
                        status: 307,
                        body: "",
                        contentType: "text/html",
                        headers: ["Location": "https://console.typesafe.ai/login?next=%2Fbilling"])
                }
                return try TypeSafeTestFixture.pluginResponse(for: request)
            },
            sessionLoader: { _ in AnySequence([.init(cookieHeader: "session=fresh", sourceLabel: "Chrome")]) },
            cacheLoader: { .authoritative(cached) },
            cacheClearer: { expected in #expect(expected == cached); log.append("cleared"); return true },
            cacheWriter: { expected, session in
                #expect(expected.entry == nil)
                log.append("stored \(session.cookieHeader)")
            })

        let result = try await strategy.fetch(Self.context(.auto))

        #expect(result.usage.providerCost?.balance == 4.98)
        #expect(log.values == ["cleared", "stored session=fresh"])
        let cookies = await requests.all.filter { $0.httpMethod != nil && $0.url?.path == "/api/billing/overview" }
            .map { $0.value(forHTTPHeaderField: "Cookie") }
        #expect(cookies == ["session=stale", "session=fresh"])
    }

    @Test
    func `non-login redirect is not treated as an expired session`() async {
        let strategy = TypeSafeWebFetchStrategy(
            transport: ProviderHTTPTransportHandler { request in
                if request.url?.path == "/api/billing/overview" {
                    return try TypeSafeTestFixture.response(
                        request,
                        status: 307,
                        body: "",
                        contentType: "text/html",
                        headers: ["Location": "https://console.typesafe.ai/billing/"])
                }
                return try TypeSafeTestFixture.pluginResponse(for: request)
            },
            sessionLoader: { _ in AnySequence([.init(cookieHeader: "session=fresh", sourceLabel: "Chrome")]) },
            cacheLoader: { .authoritative(nil) },
            cacheClearer: { _ in Issue.record("unexpected cache clear"); return false },
            cacheWriter: { _, _ in Issue.record("unexpected cache write") })

        do {
            _ = try await strategy.fetch(Self.context(.auto))
            Issue.record("expected an api failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .apiFailure)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test(arguments: [ProviderFetchClassifiedError.Kind.networkFailure, .parseFailure, .rateLimited, .apiFailure])
    func `non authentication failures preserve cache without importing`(kind: ProviderFetchClassifiedError.Kind) async {
        let error = ProviderFetchClassifiedError(kind: kind, message: "fixture")
        let strategy = TypeSafeWebFetchStrategy(
            usageLoader: { _ in throw error },
            sessionLoader: { _ in Issue.record("unexpected import"); return AnySequence([]) },
            cacheLoader: { .authoritative(.init(
                cookieHeader: "session=cached",
                storedAt: TypeSafeTestFixture.now,
                sourceLabel: "Chrome")) },
            cacheClearer: { _ in Issue.record("unexpected clear"); return false },
            cacheWriter: { _, _ in Issue.record("unexpected write") })

        await #expect(throws: error) { try await strategy.fetch(Self.context(.auto)) }
    }

    @Test
    func `temporarily unavailable cache stops before browser import`() async {
        let strategy = TypeSafeWebFetchStrategy(
            usageLoader: { _ in Issue.record("unexpected fetch"); return Self.usage() },
            sessionLoader: { _ in Issue.record("unexpected import"); return AnySequence([]) },
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
            sessionLoader: { _ in Issue.record("unexpected fallback"); return AnySequence([]) },
            cacheLoader: { .authoritative(.init(
                cookieHeader: "session=pinned",
                storedAt: TypeSafeTestFixture.now,
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
            storedAt: TypeSafeTestFixture.now,
            sourceLabel: "old")
        let strategy = TypeSafeWebFetchStrategy(
            usageLoader: { header in
                if header == cached.cookieHeader {
                    throw ProviderFetchClassifiedError(kind: .authenticationExpired, message: "fixture")
                }
                return Self.usage()
            },
            sessionLoader: { _ in AnySequence([.init(cookieHeader: "session=new", sourceLabel: "new")]) },
            cacheLoader: { .authoritative(cached) },
            cacheClearer: { _ in false },
            cacheWriter: { expected, _ in #expect(expected.entry == cached) })

        _ = try await strategy.fetch(Self.context(.auto))
    }

    @Test
    func `cancellation cannot publish candidate to cache`() async {
        let strategy = TypeSafeWebFetchStrategy(
            usageLoader: { _ in withUnsafeCurrentTask { $0?.cancel() }; return Self.usage() },
            sessionLoader: { _ in AnySequence([.init(cookieHeader: "session=fixture", sourceLabel: "Chrome")]) },
            cacheLoader: { .authoritative(nil) },
            cacheClearer: { _ in Issue.record("unexpected clear"); return false },
            cacheWriter: { _, _ in Issue.record("cancelled cache write") })
        let task = Task { try await strategy.fetch(Self.context(.auto)) }

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(arguments: [false, true])
    func `browser candidates stop at the first validated session`(expiredFirst: Bool) async throws {
        let log = Log()
        let strategy = TypeSafeWebFetchStrategy(
            usageLoader: { cookie in
                log.append("fetch " + cookie)
                if cookie == "session=expired" {
                    throw ProviderFetchClassifiedError(kind: .authenticationExpired, message: "fixture")
                }
                return Self.usage()
            },
            sessionLoader: { _ in
                var cookies = (expiredFirst ? ["session=expired", "session=valid", "session=unused"]
                    : ["session=valid", "session=unused"]).makeIterator()
                return AnySequence(AnyIterator {
                    guard let cookie = cookies.next() else { return nil }
                    log.append("load " + cookie)
                    return TypeSafeResolvedSession(cookieHeader: cookie, sourceLabel: "fixture")
                })
            },
            cacheLoader: { .authoritative(nil) },
            cacheClearer: { _ in Issue.record("unexpected clear"); return false },
            cacheWriter: { _, session in #expect(session.cookieHeader == "session=valid") })
        _ = try await strategy.fetch(Self.context(.auto))
        let expected = (expiredFirst ? ["load session=expired", "fetch session=expired"] : [])
            + ["load session=valid", "fetch session=valid"]
        #expect(log.values == expected)
    }

    private static func record(
        _ domain: String,
        scope: BrowserCookieScope,
        name: String,
        value: String = "value",
        path: String = "/") -> BrowserCookieRecord
    {
        BrowserCookieRecord(
            domain: domain,
            name: name,
            path: path,
            value: value,
            expires: nil,
            isSecure: true,
            isHTTPOnly: true,
            scope: scope)
    }

    private static func usage() -> UsageSnapshot {
        UsageSnapshot(primary: nil, secondary: nil, updatedAt: TypeSafeTestFixture.now)
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
