import Foundation
import Testing
@testable import CodexBarCore

struct GrokBotUsageEnrichmentTests {
    @Test
    func `disabled tracking does not fetch Cursor or change Grok usage`() async throws {
        let original = Self.grokResult()
        let strategy = GrokBotUsageEnrichment(base: StubStrategy(result: .success(original))) { _ in
            Issue.record("Disabled tracking must not access Cursor")
            throw URLError(.badServerResponse)
        }
        let context = Self.context(enabled: false)
        let result = try await strategy.fetch(context)
        #expect(await strategy.isAvailable(context) == false)
        #expect(result.usage.primary == original.usage.primary)
        #expect(result.usage.extraRateWindows == nil)
    }

    @Test(arguments: [0.0, 42.0, 100.0])
    func `Bot allowance remains independent of Grok subscription and identity`(percent: Double) async throws {
        let original = Self.grokResult()
        let bot = Self.botWindow(percent: percent)
        let strategy = GrokBotUsageEnrichment(base: StubStrategy(result: .success(original))) { _ in bot }
        let result = try await strategy.fetch(Self.context(enabled: true))
        #expect(result.usage.primary == original.usage.primary)
        #expect(result.usage.secondary == original.usage.secondary)
        #expect(result.usage.accountEmail(for: .grok) == "grok@example.com")
        #expect(result.usage.loginMethod(for: .grok) == "SuperGrok")
        #expect(result.usage.accountEmail(for: .cursor) == nil)
        #expect(result.usage.extraRateWindows == [bot])
        #expect(result.sourceLabel == original.sourceLabel)
        #expect(result.diagnostic == original.diagnostic)
        #expect(result.supplementalUsageTask != nil)
    }

    @Test
    func `optional Bot failure stays unknown while Grok billing succeeds`() async throws {
        let strategy = GrokBotUsageEnrichment(base: StubStrategy(result: .success(Self.grokResult()))) { _ in
            throw CursorStatusProbeError.noSessionCookie
        }
        let result = try await strategy.fetch(Self.context(enabled: true))
        #expect(result.usage.primary?.usedPercent == 23)
        let bot = try #require(result.usage.extraRateWindows?.first)
        #expect(bot.title == "Grok Bot")
        #expect(!bot.usageKnown)
        #expect(bot.window.resetsAt == nil)
        #expect(result.diagnostic ==
            "Existing Grok diagnostic Grok Bot needs the linked Cursor account. Sign in under Cursor settings.")
    }

    @Test
    func `required Grok failure reaches normal fallback before fetching Bot`() async throws {
        let strategy = GrokBotUsageEnrichment(base: StubStrategy(result: .failure(URLError(.badServerResponse)))) { _ in
            Issue.record("A failed base must leave the Bot lookup to the final fallback")
            return Self.botWindow()
        }
        await #expect(throws: URLError.self) { try await strategy.fetch(Self.context(enabled: true)) }
        #expect(strategy.shouldFallback(on: URLError(.badServerResponse), context: Self.context(enabled: true)))
    }

    @Test
    func `Bot-only fallback works without Grok login and invents no identity or subscription quota`() async throws {
        let bot = Self.botWindow()
        let strategy = GrokBotUsageEnrichment { _ in bot }
        let result = try await strategy.fetch(Self.context(enabled: true))
        #expect(result.usage.primary == nil)
        #expect(result.usage.secondary == nil)
        #expect(result.usage.extraRateWindows == [bot])
        #expect(result.usage.accountEmail(for: .grok) == nil)
        #expect(result.usage.loginMethod(for: .grok) == nil)
        #expect(result.sourceLabel == "grok-bot-cursor")
        #expect(!strategy.shouldFallback(on: URLError(.badServerResponse), context: Self.context(enabled: true)))
    }

    @Test(arguments: [ProviderCookieSource.off, .manual])
    func `disabled or empty manual Cursor credentials never fall through to ambient credentials`(
        source: ProviderCookieSource) async throws
    {
        await #expect(throws: CursorStatusProbeError.self) {
            try await GrokBotUsageEnrichment.fetchBotUsage(Self.context(enabled: true, cursorSource: source))
        }
    }

    @Test
    func `explicit Cursor Off remains authoritative over automatic Bot routing`() async throws {
        await #expect(throws: CursorStatusProbeError.self) {
            try await GrokBotUsageEnrichment.fetchBotUsage(
                Self.context(enabled: true, cursorSource: .off, botCursorSource: .auto),
                makeProbe: {
                    Issue.record("Explicit Off must prevent probe creation")
                    return CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
                })
        }
    }

    @Test
    func `cancellation is not turned into an unavailable reading`() async throws {
        let strategy = GrokBotUsageEnrichment(base: StubStrategy(result: .success(Self.grokResult()))) { _ in
            throw CancellationError()
        }
        await #expect(throws: CancellationError.self) { try await strategy.fetch(Self.context(enabled: true)) }
        #expect(!strategy.shouldFallback(on: CancellationError(), context: Self.context(enabled: true)))
        #expect(!strategy.shouldFallback(on: URLError(.cancelled), context: Self.context(enabled: true)))
    }

    @Test
    func `optional Bot lookup has a bounded wait`() async throws {
        let strategy = GrokBotUsageEnrichment(base: StubStrategy(result: .success(Self.grokResult()))) { _ in
            try await Task.sleep(for: .seconds(60))
            return Self.botWindow()
        }
        let immediateTimeout: @Sendable (Duration) async throws -> Void = { _ in }
        let result = try await BoundedTaskJoinTiming.$sleep.withValue(immediateTimeout) {
            try await strategy.fetch(Self.context(enabled: true))
        }
        #expect(result.usage.primary?.usedPercent == 23)
        #expect(result.usage.extraRateWindows?.first?.usageKnown == false)
        #expect(result.diagnostic == "Existing Grok diagnostic Grok Bot lookup timed out.")
    }

    @Test
    func `Bot failures report safe HTTP diagnostics without exposing response contents`() async throws {
        let serverFailure = GrokBotUsageEnrichment(base: StubStrategy(result: .success(Self.grokResult()))) { _ in
            throw CursorStatusProbeError.networkError("HTTP 429")
        }
        let serverResult = try await serverFailure.fetch(Self.context(enabled: true))
        #expect(serverResult.diagnostic == "Existing Grok diagnostic Grok Bot lookup failed (HTTP 429).")
        let malformed = GrokBotUsageEnrichment(base: StubStrategy(result: .success(Self.grokResult()))) { _ in
            throw CursorStatusProbeError.parseFailed("Raw: private response fixture")
        }
        let malformedResult = try await malformed.fetch(Self.context(enabled: true))
        #expect(malformedResult.diagnostic?.contains("readable allowance") == true)
        #expect(malformedResult.diagnostic?.contains("private response") == false)
    }

    @Test
    func `Bot lookup uses only the Sand endpoint and the supplied Cursor session`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?.path == CursorSandUsageStatus.endpointPath)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=fixture-cursor")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://cursor.com")
            #expect(request.timeoutInterval <= 5)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (
                Data("""
                {"includedLimitZero":false,"usagePercent":42,"nextResetTimestampUtc":"2026-10-18T12:00:00Z"}
                """.utf8),
                response)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let probe = CursorStatusProbe(
            timeout: 5,
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: transport,
            sessionStore: CursorSessionStore(fileURL: root.appendingPathComponent("session.json")))
        let status = try await probe.fetchGrokBotUsage(
            cookieHeaderOverride: "WorkosCursorSessionToken=fixture-cursor", allowAppAuthFallback: false)
        #expect(status.usagePercent == 42)
        #expect(await transport.requests().count == 1)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    #if os(macOS)
    @Test(ProviderTransportRegressionFixtures())
    func `automatic Bot routing can use local app auth when cookies are masked as empty manual`() async throws {
        let root = ProviderTransportRegressionFixtures.root
        let claims: [String: Any] = [
            "sub": "user_fixture", "exp": Date().addingTimeInterval(3600).timeIntervalSince1970,
        ]
        let payload = try JSONSerialization.data(withJSONObject: claims)
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let session = CursorAppAuthSession(accessToken: "fixture.\(encoded).signature")
        let cookieHeader = try session.cookieHeader()
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?.path == CursorSandUsageStatus.endpointPath)
            #expect(request.value(forHTTPHeaderField: "Cookie") == cookieHeader)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data("{\"includedLimitZero\":false,\"usagePercent\":42}".utf8), response)
        }
        let probe = CursorStatusProbe(
            browserDetection: ProviderTransportRegressionSupport.browser(root: root),
            browserCookieImportOrder: [],
            urlSession: transport,
            appAuthStore: CursorAppAuthSessionProviderStub(session: session),
            sessionStore: CursorSessionStore(fileURL: root.appendingPathComponent("session.json")))
        let context = Self.context(enabled: true, cursorSource: .manual, botCursorSource: .auto)
        let window = try await GrokBotUsageEnrichment.fetchBotUsage(context, makeProbe: { probe })
        #expect(window.usageKnown)
        #expect(window.window.usedPercent == 42)
        #expect(await transport.requests().count == 1)
    }
    #endif

    @Test
    func `Grok pipeline only includes Bot strategies after explicit opt in`() async {
        let pipeline = GrokProviderDescriptor.descriptor.fetchPlan.pipeline
        let off = await pipeline.resolveStrategies(Self.context(enabled: false))
        let on = await pipeline.resolveStrategies(Self.context(enabled: true))
        #expect(off.map(\.id) == ["grok.oauth"])
        #expect(on.map(\.id) == ["grok.oauth", "grok.bot"])
        #expect(off.first is GrokOAuthFetchStrategy)
        #expect(on.first is GrokBotUsageEnrichment)
    }

    @Test
    func `turning tracking off removes only the Bot extra`() {
        let other = NamedRateWindow(
            id: "other", title: "Other", window: Self.botWindow().window)
        let original = Self.grokResult().usage.replacing(extraRateWindows: .value([Self.botWindow(), other]))
        let cleared = GrokBotUsageEnrichment.removingBotUsage(from: original)
        #expect(cleared.extraRateWindows == [other])
        #expect(cleared.primary == original.primary)
        #expect(cleared.accountEmail(for: .grok) == "grok@example.com")
    }

    private static func context(
        enabled: Bool,
        cursorSource: ProviderCookieSource = .auto,
        botCursorSource: ProviderCookieSource? = nil) -> ProviderFetchContext
    {
        let browser = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .oauth,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: ProviderSettingsSnapshot(contributions: [
                .grok(GrokProviderSettings(
                    cookieSource: .off,
                    manualCookieHeader: nil,
                    grokBotUsageEnabled: enabled,
                    grokBotCursorCookieSource: botCursorSource)),
                .cursor(CursorProviderSettings(cookieSource: cursorSource, manualCookieHeader: nil)),
            ]),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browser),
            browserDetection: browser)
    }

    private static func grokResult() -> ProviderFetchResult {
        ProviderFetchResult(
            usage: UsageSnapshot(
                primary: RateWindow(usedPercent: 23, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 5, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                tertiary: nil,
                updatedAt: Date(timeIntervalSince1970: 100),
                identity: ProviderIdentitySnapshot(
                    providerID: .grok,
                    accountEmail: "grok@example.com",
                    accountOrganization: nil,
                    loginMethod: "SuperGrok")),
            credits: nil,
            dashboard: nil,
            sourceLabel: "grok-cli-proxy",
            strategyID: "grok.oauth",
            strategyKind: .oauth,
            supplementalUsageTask: Task { .grokResetCredits(nil) },
            diagnostic: "Existing Grok diagnostic")
    }

    private static func botWindow(percent: Double = 42) -> NamedRateWindow {
        NamedRateWindow(
            id: CursorSandUsageStatus.extraWindowID,
            title: CursorSandUsageStatus.extraWindowTitle,
            window: RateWindow(
                usedPercent: percent,
                windowMinutes: 10080,
                resetsAt: Date(timeIntervalSince1970: 800_000),
                resetDescription: nil))
    }

    private struct StubStrategy: ProviderFetchStrategy {
        let result: Result<ProviderFetchResult, Error>
        let id = "grok.oauth"
        let kind = ProviderFetchKind.oauth
        func isAvailable(_: ProviderFetchContext) async -> Bool { true }
        func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult { try self.result.get() }
        func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool { false }
    }
}
