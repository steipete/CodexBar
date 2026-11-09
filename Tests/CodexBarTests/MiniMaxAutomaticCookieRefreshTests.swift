import Foundation
import Testing
@testable import CodexBarCore

struct MiniMaxAutomaticCookieRefreshTests {
    @Test
    func `expired cached session reloads and caches a validated browser session`() async throws {
        let expired = self.session("expired")
        let fresh = self.session("fresh")
        var fetched: [String] = []
        var cleared: [MiniMaxWebSessionDomain] = []
        var stored: [String] = []
        var browserReads = 0

        let result = try await MiniMaxCodingPlanFetchStrategy.fetchAutomatic(
            cached: [expired],
            fetchSession: { session in
                fetched.append(session.cookieHeader)
                if session.cookieHeader == expired.cookieHeader { throw MiniMaxUsageError.invalidCredentials }
                return Self.snapshot
            },
            browserSessions: {
                browserReads += 1
                return AnySequence([fresh])
            },
            clearCached: { cleared.append($0.domain) },
            storeResolved: { stored.append($0.cookieHeader) })

        #expect(result.usedPercent == 23)
        #expect(fetched == [expired.cookieHeader, fresh.cookieHeader])
        #expect(cleared == [.chinaMainland])
        #expect(stored == [fresh.cookieHeader])
        #expect(browserReads == 1)
    }

    @Test(arguments: [false, true])
    func `network and service failures keep cached credentials without browser reads`(network: Bool) async {
        var cleared = false
        var stored = false
        var browserRead = false
        do {
            _ = try await MiniMaxCodingPlanFetchStrategy.fetchAutomatic(
                cached: [self.session("existing")],
                fetchSession: { _ in
                    if network { throw URLError(.notConnectedToInternet) }
                    throw MiniMaxUsageError.apiError("HTTP 503")
                },
                browserSessions: { browserRead = true; return AnySequence([]) },
                clearCached: { _ in cleared = true },
                storeResolved: { _ in stored = true })
            Issue.record("Expected the original request error")
        } catch {
            if network {
                #expect((error as? URLError)?.code == .notConnectedToInternet)
            } else {
                #expect(error as? MiniMaxUsageError == .apiError("HTTP 503"))
            }
        }
        #expect(!cleared && !stored && !browserRead)
    }

    @Test
    func `empty browser rediscovery preserves the original authentication failure`() async {
        await #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try await MiniMaxCodingPlanFetchStrategy.fetchAutomatic(
                cached: [self.session("expired")],
                fetchSession: { _ in throw MiniMaxUsageError.invalidCredentials },
                browserSessions: { AnySequence([]) },
                clearCached: { _ in },
                storeResolved: { _ in Issue.record("Unvalidated session must not be cached") })
        }
    }

    @Test
    func `schema failure tries a browser without deleting cached credentials`() async throws {
        let cached = self.session("existing")
        var cleared = false
        _ = try await MiniMaxCodingPlanFetchStrategy.fetchAutomatic(
            cached: [cached],
            fetchSession: { session in
                if session.cookieHeader == cached.cookieHeader { throw MiniMaxUsageError.parseFailed("fixture schema") }
                return Self.snapshot
            },
            browserSessions: { AnySequence([self.session("fresh")]) },
            clearCached: { _ in cleared = true },
            storeResolved: { _ in })
        #expect(!cleared)
    }

    @Test
    func `region caches ignore old unscoped and other region credentials`() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minimax-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        await KeychainCacheStore.withImplicitTestStoreForTesting {
            await KeychainCacheStore.withServiceOverrideForTesting("minimax-cache-\(UUID())") {
                await CookieHeaderCache.withLegacyBaseURLOverrideForTesting(directory) {
                    CookieHeaderCache.store(provider: .minimax, cookieHeader: "_token=old-mixed", sourceLabel: "Old")
                    CookieHeaderCache.store(
                        provider: .minimax,
                        scope: .providerVariant("minimax.web-session.v1.chinaMainland"),
                        cookieHeader: "_token=old-scoped",
                        sourceLabel: "Old scoped")
                    let context = self.cliContext()
                    #expect(await MiniMaxCodingPlanFetchStrategy().isAvailable(context) == false)
                    let global = MiniMaxWebSessionDomain.global.cacheScope
                    CookieHeaderCache.store(
                        provider: .minimax, scope: global, cookieHeader: "_token=global", sourceLabel: "Global")
                    #expect(await MiniMaxCodingPlanFetchStrategy().isAvailable(context) == false)
                    let china = MiniMaxWebSessionDomain.chinaMainland.cacheScope
                    CookieHeaderCache.store(
                        provider: .minimax, scope: china, cookieHeader: "_token=china", sourceLabel: "China")
                    #expect(await MiniMaxCodingPlanFetchStrategy().isAvailable(context))
                    CookieHeaderCache.clear(provider: .minimax, scope: china)
                    #expect(CookieHeaderCache.load(provider: .minimax, scope: global)?.cookieHeader == "_token=global")
                    #expect(CookieHeaderCache.load(provider: .minimax)?.cookieHeader == "_token=old-mixed")
                }
            }
        }
    }

    private func session(_ token: String) -> MiniMaxWebSession {
        MiniMaxWebSession(cookieHeader: "_token=\(token)", sourceLabel: "Fixture Default", domain: .chinaMainland)
    }

    private static let snapshot = MiniMaxUsageSnapshot(
        planName: "Fixture Plan",
        availablePrompts: nil,
        currentPrompts: nil,
        remainingPrompts: nil,
        windowMinutes: 300,
        usedPercent: 23,
        resetsAt: nil,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

    private func cliContext() -> ProviderFetchContext {
        ProviderFetchContext(
            runtime: .cli,
            sourceMode: .web,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: .make(minimax: .init(cookieSource: .auto, manualCookieHeader: nil, apiRegion: .chinaMainland)),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(homeDirectory: "/synthetic/minimax-no-browser"))
    }

    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot { throw URLError(.unsupportedURL) }
        func debugRawProbe(model _: String) async -> String { "fixture" }
        func detectVersion() -> String? { nil }
    }
}
