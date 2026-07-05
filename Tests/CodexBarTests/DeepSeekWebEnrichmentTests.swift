import Foundation
import Testing
@testable import CodexBarCore

private struct DeepSeekWebEnrichmentTestClaudeFetcher: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw DeepSeekUsageError.missingCredentials
    }

    func debugRawProbe(model _: String) async -> String {
        "stub"
    }

    func detectVersion() -> String? {
        nil
    }
}

private enum DeepSeekWebEnrichmentTestSupport {
    static func makeContext(
        env: [String: String] = [:],
        settings: ProviderSettingsSnapshot? = nil) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .cli,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: DeepSeekWebEnrichmentTestClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }
}

struct DeepSeekPlatformSessionTests {
    @Test
    func `session parser accepts cookie header`() throws {
        let session = try #require(DeepSeekCookieHeader.session(from: "session=abc; path=/"))
        #expect(session.cookieHeader == "session=abc; path=/")
        #expect(session.authorizationHeader == nil)
    }

    @Test
    func `session parser accepts bearer authorization header`() throws {
        let session = try #require(DeepSeekCookieHeader.session(from: "Bearer eyJ.test.token"))
        #expect(session.cookieHeader == nil)
        #expect(session.authorizationHeader == "Bearer eyJ.test.token")
    }

    @Test
    func `session parser accepts devtools authorization line`() throws {
        let raw = """
        Authorization: Bearer eyJ.test.token
        Cookie: session=abc
        """
        let session = try #require(DeepSeekCookieHeader.session(from: raw))
        #expect(session.authorizationHeader == "Bearer eyJ.test.token")
        #expect(session.cookieHeader == "session=abc")
    }

    @Test
    func `header includes chat ds_session_id for platform apis`() throws {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .domain: "chat.deepseek.com",
            .path: "/",
            .name: "ds_session_id",
            .value: "abc123",
            .secure: "TRUE",
        ]
        let cookie = try #require(HTTPCookie(properties: properties))
        let header = DeepSeekCookieHeader.header(from: [cookie])
        #expect(header?.contains("ds_session_id=abc123") == true)
    }

    @Test
    func `header ignores waf only cookies`() throws {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .domain: "platform.deepseek.com",
            .path: "/",
            .name: "HWWAFSESID",
            .value: "waf",
            .secure: "TRUE",
        ]
        let cookie = try #require(HTTPCookie(properties: properties))
        #expect(DeepSeekCookieHeader.header(from: [cookie]) == nil)
    }

    @Test
    func `auth failure payload detection recognizes platform codes`() {
        let payload = Data("""
        {"code":40003,"msg":"Authorization Failed"}
        """.utf8)
        #expect(DeepSeekCookieHeader.isAuthFailurePayload(payload))
    }

    @Test
    func `usage parser maps auth failure code to invalid credentials`() throws {
        let amount = Data("""
        {"code":40003,"msg":"Authorization Failed","data":null}
        """.utf8)
        let cost = Data("""
        {"code":0,"msg":"","data":{"biz_code":0,"biz_data":[]}}
        """.utf8)

        do {
            _ = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(amountData: amount, costData: cost)
            Issue.record("Expected invalid credentials")
        } catch DeepSeekUsageError.invalidCredentials {
            #expect(Bool(true))
        }
    }
}

struct DeepSeekWebEnrichmentResolverTests {
    @Test
    func `explicit env cookie becomes enrichment candidate`() {
        CookieHeaderCache.clear(provider: .deepseek)
        let context = DeepSeekWebEnrichmentTestSupport.makeContext(
            env: ["DEEPSEEK_COOKIE": "session=abc"],
            settings: ProviderSettingsSnapshot.make(deepseek: .init(cookieSource: .auto, manualCookieHeader: nil)))
        let candidates = DeepSeekWebEnrichmentResolver.candidates(context: context)
        let envCandidates = candidates.filter { $0.sourceLabel == "environment" }
        #expect(envCandidates.count == 1)
        #expect(envCandidates[0].session.cookieHeader == "session=abc")
    }

    @Test
    func `cookie source off yields no candidates`() {
        let context = DeepSeekWebEnrichmentTestSupport.makeContext(
            env: ["DEEPSEEK_COOKIE": "session=abc"],
            settings: ProviderSettingsSnapshot.make(deepseek: .init(cookieSource: .off, manualCookieHeader: nil)))
        let candidates = DeepSeekWebEnrichmentResolver.candidates(context: context)
        #expect(candidates.isEmpty)
    }

    @Test
    func `manual mode uses pasted session only`() {
        let context = DeepSeekWebEnrichmentTestSupport.makeContext(
            env: ["DEEPSEEK_COOKIE": "session=env"],
            settings: ProviderSettingsSnapshot.make(deepseek: .init(
                cookieSource: .manual,
                manualCookieHeader: "session=manual")))
        let candidates = DeepSeekWebEnrichmentResolver.candidates(context: context)
        #expect(candidates.count == 1)
        #expect(candidates[0].sourceLabel == "settings")
        #expect(candidates[0].session.cookieHeader == "session=manual")
    }

    @Test
    func `manual mode ignores cached session`() {
        CookieHeaderCache.store(
            provider: .deepseek,
            cookieHeader: "session=cached",
            sourceLabel: "Chrome")
        defer { CookieHeaderCache.clear(provider: .deepseek) }

        let context = DeepSeekWebEnrichmentTestSupport.makeContext(
            env: [:],
            settings: ProviderSettingsSnapshot.make(deepseek: .init(
                cookieSource: .manual,
                manualCookieHeader: "session=manual")))
        let candidates = DeepSeekWebEnrichmentResolver.candidates(context: context)
        #expect(candidates.count == 1)
        #expect(candidates[0].session.cookieHeader == "session=manual")
    }

    @Test
    func `configured web session detects manual header`() {
        let settings = ProviderSettingsSnapshot.make(deepseek: .init(
            cookieSource: .manual,
            manualCookieHeader: "session=manual"))
        #expect(DeepSeekWebEnrichmentResolver.hasConfiguredWebSession(
            settings: settings,
            environment: [:]))
    }

    @Test
    func `configured web session detects env cookie in auto mode`() {
        let settings = ProviderSettingsSnapshot.make(deepseek: .init(cookieSource: .auto, manualCookieHeader: nil))
        #expect(DeepSeekWebEnrichmentResolver.hasConfiguredWebSession(
            settings: settings,
            environment: ["DEEPSEEK_COOKIE": "session=env"]))
    }

    #if os(macOS)
    @Test
    func `browser import requires user initiated app refresh`() {
        let appContext = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: ProviderSettingsSnapshot.make(deepseek: .init(cookieSource: .auto, manualCookieHeader: nil)),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: DeepSeekWebEnrichmentTestClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
        let cliContext = ProviderFetchContext(
            runtime: .cli,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: ProviderSettingsSnapshot.make(deepseek: .init(cookieSource: .auto, manualCookieHeader: nil)),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: DeepSeekWebEnrichmentTestClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))

        #expect(DeepSeekWebEnrichmentResolver.allowsBrowserCookieImport(context: appContext) == false)
        #expect(DeepSeekWebEnrichmentResolver.allowsBrowserCookieImport(context: cliContext) == false)

        ProviderInteractionContext.$current.withValue(.userInitiated) {
            #expect(DeepSeekWebEnrichmentResolver.allowsBrowserCookieImport(context: appContext))
            #expect(DeepSeekWebEnrichmentResolver.allowsBrowserCookieImport(context: cliContext) == false)
        }
    }
    #endif
}
