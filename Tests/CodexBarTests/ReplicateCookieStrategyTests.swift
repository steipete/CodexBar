import Foundation
import Testing
@testable import CodexBarCore

struct ReplicateCookieStrategyTests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func append(_ entry: String) { self.lock.withLock { self.entries.append(entry) } }
        var values: [String] {
            self.lock.withLock { self.entries }
        }
    }

    @Test
    func `manual cookies never load import or cache credentials`() async throws {
        let log = Log()
        let strategy = ReplicateWebFetchStrategy(
            usageLoader: { cookie in log.append(cookie); return Self.usage() },
            sessionLoader: { _ in Issue.record("unexpected import"); return [] },
            cacheLoader: { Issue.record("unexpected cache read"); return .authoritative(nil) },
            cacheClearer: { _ in Issue.record("unexpected cache clear"); return false },
            cacheWriter: { _, _ in Issue.record("unexpected cache write") })
        _ = try await strategy.fetch(Self.context(.manual, header: "sessionid=manual"))
        #expect(log.values == ["sessionid=manual"])
    }

    @Test
    func `authentication failure clears only observed cache and tries every candidate`() async throws {
        let log = Log()
        let cached = CookieHeaderCache.Entry(
            cookieHeader: "sessionid=cached",
            storedAt: ReplicatePluginTests.now,
            sourceLabel: "old")
        let strategy = ReplicateWebFetchStrategy(
            usageLoader: { cookie in
                log.append(cookie)
                guard cookie == "sessionid=valid" else {
                    throw ProviderFetchClassifiedError(kind: .authenticationExpired, message: "fixture")
                }
                return Self.usage()
            },
            sessionLoader: { _ in [
                .init(cookieHeader: "sessionid=expired; csrftoken=optional", sourceLabel: "Chrome A"),
                .init(cookieHeader: "sessionid=valid", sourceLabel: "Chrome B"),
            ] },
            cacheLoader: { .authoritative(cached) },
            cacheClearer: { expected in #expect(expected == cached); return true },
            cacheWriter: { expected, session in
                #expect(expected.entry == nil)
                #expect(session.sourceLabel == "Chrome B")
                log.append("stored")
            })
        _ = try await strategy.fetch(Self.context(.auto))
        #expect(log.values == [
            "sessionid=cached",
            "sessionid=expired; csrftoken=optional",
            "sessionid=valid",
            "stored",
        ])
    }

    @Test(arguments: [ProviderFetchClassifiedError.Kind.networkFailure, .parseFailure, .rateLimited])
    func `non authentication failures preserve cached account`(kind: ProviderFetchClassifiedError.Kind) async {
        let error = ProviderFetchClassifiedError(kind: kind, message: "fixture")
        let strategy = ReplicateWebFetchStrategy(
            usageLoader: { _ in throw error },
            sessionLoader: { _ in Issue.record("unexpected account fallback"); return [] },
            cacheLoader: { .authoritative(.init(
                cookieHeader: "sessionid=cached",
                storedAt: ReplicatePluginTests.now,
                sourceLabel: "Chrome")) },
            cacheClearer: { _ in Issue.record("unexpected clear"); return false },
            cacheWriter: { _, _ in Issue.record("unexpected write") })
        await #expect(throws: error) { try await strategy.fetch(Self.context(.auto)) }
    }

    @Test
    func `unreadable cache cannot select another browser account`() async {
        let strategy = ReplicateWebFetchStrategy(
            usageLoader: { _ in Issue.record("unexpected fetch"); return Self.usage() },
            sessionLoader: { _ in Issue.record("unexpected import"); return [] },
            cacheLoader: { .keychainTemporarilyUnavailable(legacyEntry: nil) },
            cacheClearer: { _ in Issue.record("unexpected clear"); return false },
            cacheWriter: { _, _ in Issue.record("unexpected write") })
        await #expect(throws: ReplicateCredentialError.cacheUnavailable) {
            try await strategy.fetch(Self.context(.auto))
        }
    }

    @Test
    func `pinned cached account never falls back after authentication failure`() async {
        let error = ProviderFetchClassifiedError(kind: .authenticationExpired, message: "fixture")
        let strategy = ReplicateWebFetchStrategy(
            usageLoader: { _ in throw error },
            sessionLoader: { _ in Issue.record("unexpected pinned account fallback"); return [] },
            cacheLoader: { .authoritative(.init(
                cookieHeader: "sessionid=pinned",
                storedAt: ReplicatePluginTests.now,
                sourceLabel: "pinned",
                authenticationFailurePolicy: .stopFallback)) },
            cacheClearer: { _ in Issue.record("unexpected pinned cache clear"); return false },
            cacheWriter: { _, _ in Issue.record("unexpected pinned cache write") })
        await #expect(throws: error) { try await strategy.fetch(Self.context(.auto)) }
    }

    @Test
    func `a concurrently replaced cache is never overwritten`() async throws {
        let cached = CookieHeaderCache.Entry(
            cookieHeader: "sessionid=old",
            storedAt: ReplicatePluginTests.now,
            sourceLabel: "old")
        let strategy = ReplicateWebFetchStrategy(
            usageLoader: { header in
                if header == cached.cookieHeader { throw ProviderFetchClassifiedError(
                    kind: .authenticationExpired,
                    message: "fixture") }
                return Self.usage()
            },
            sessionLoader: { _ in [.init(cookieHeader: "sessionid=new", sourceLabel: "new")] },
            cacheLoader: { .authoritative(cached) },
            cacheClearer: { _ in false },
            cacheWriter: { expected, _ in #expect(expected.entry == cached) })
        _ = try await strategy.fetch(Self.context(.auto))
    }

    @Test
    func `cancellation cannot publish a candidate to the cache`() async {
        let strategy = ReplicateWebFetchStrategy(
            usageLoader: { _ in withUnsafeCurrentTask { $0?.cancel() }; return Self.usage() },
            sessionLoader: { _ in [.init(cookieHeader: "sessionid=fixture", sourceLabel: "Chrome")] },
            cacheLoader: { .authoritative(nil) },
            cacheClearer: { _ in Issue.record("unexpected clear"); return false },
            cacheWriter: { _, _ in Issue.record("cancelled cache write") })
        let task = Task { try await strategy.fetch(Self.context(.auto)) }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    #if os(macOS)
    @Test
    func `browser import is Chrome only and session cookies do not require CSRF`() throws {
        #expect(ReplicateCookieImporter.resolvedImportOrder(nil) == [.chrome])
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "replicate.com",
            .path: "/",
            .name: "sessionid",
            .value: "fixture",
        ]))
        #expect(ReplicateCookieImporter.hasSessionCookie([cookie]))
        #expect(!ReplicateCookieImporter.hasSessionCookie([]))
    }
    #endif

    private static func usage() -> UsageSnapshot {
        UsageSnapshot(primary: nil, secondary: nil, updatedAt: ReplicatePluginTests.now)
    }

    private static func context(_ source: ProviderCookieSource, header: String? = nil) -> ProviderFetchContext {
        let browser = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .web,
            includeCredits: true,
            webTimeout: 20,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: .make(replicate: .init(cookieSource: source, manualCookieHeader: header)),
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browser),
            browserDetection: browser)
    }
}
