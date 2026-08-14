import Foundation
import Testing
@testable import CodexBarCore

private enum CursorAppTokenStrategyTestError: Error {
    case unused
}

private struct CursorAppTokenStrategyStubClaudeFetcher: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw CursorAppTokenStrategyTestError.unused
    }

    func debugRawProbe(model _: String) async -> String {
        "stub"
    }

    func detectVersion() -> String? {
        nil
    }
}

private struct CursorAppTokenStoreStub: CursorAppAuthSessionProviding {
    let session: CursorAppAuthSession?

    func loadSession() throws -> CursorAppAuthSession? {
        self.session
    }
}

private func makeCursorAppTokenJWT(expiration: Date = Date(timeIntervalSinceNow: 3600)) throws -> String {
    let payload = try JSONSerialization.data(
        withJSONObject: [
            "exp": Int(expiration.timeIntervalSince1970),
            "sub": "auth0|user_test",
        ],
        options: [.sortedKeys])
    let encodedPayload = payload.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(encodedPayload).signature"
}

struct CursorAppTokenStrategyTests {
    @Test
    func `descriptor exposes oauth source mode`() {
        #expect(CursorProviderDescriptor.descriptor.fetchPlan.sourceModes.contains(.oauth))
    }

    @Test
    func `oauth mode resolves only the app token strategy`() async {
        let strategies = await Self.resolveStrategies(sourceMode: .oauth)
        #expect(strategies.map(\.id) == ["cursor.oauth"])
        #expect(strategies.map(\.kind) == [.oauth])
    }

    @Test
    func `auto mode prefers the app token strategy before web`() async {
        let strategies = await Self.resolveStrategies(sourceMode: .auto)
        #expect(strategies.map(\.id) == ["cursor.oauth", "cursor.web"])
    }

    @Test
    func `web and cli modes resolve only the web strategy`() async {
        let webStrategies = await Self.resolveStrategies(sourceMode: .web)
        #expect(webStrategies.map(\.id) == ["cursor.web"])

        let cliStrategies = await Self.resolveStrategies(sourceMode: .cli)
        #expect(cliStrategies.map(\.id) == ["cursor.web"])
    }

    @Test
    func `usable app session is available in oauth mode`() async throws {
        let token = try makeCursorAppTokenJWT()
        let strategy = CursorAppTokenFetchStrategy(
            appAuthStore: CursorAppTokenStoreStub(session: CursorAppAuthSession(accessToken: token)),
            loadCachedEntry: { nil })
        #expect(await strategy.isAvailable(Self.makeContext(sourceMode: .oauth)))
    }

    @Test
    func `missing app session is unavailable and fetch surfaces not logged in`() async {
        let strategy = CursorAppTokenFetchStrategy(
            appAuthStore: CursorAppTokenStoreStub(session: nil),
            loadCachedEntry: { nil })
        let context = Self.makeContext(sourceMode: .oauth)

        #expect(await strategy.isAvailable(context) == false)
        await #expect(throws: CursorStatusProbeError.self) {
            _ = try await strategy.fetch(context)
        }
    }

    @Test
    func `expired app session is unavailable`() async throws {
        let token = try makeCursorAppTokenJWT(expiration: Date(timeIntervalSinceNow: -60))
        let strategy = CursorAppTokenFetchStrategy(
            appAuthStore: CursorAppTokenStoreStub(session: CursorAppAuthSession(accessToken: token)),
            loadCachedEntry: { nil })
        #expect(await strategy.isAvailable(Self.makeContext(sourceMode: .auto)) == false)
    }

    @Test
    func `explicitly selected browser login keeps winning auto mode`() async throws {
        let token = try makeCursorAppTokenJWT()
        let selectedEntry = CookieHeaderCache.Entry(
            cookieHeader: "WorkosCursorSessionToken=selected",
            storedAt: Date(),
            sourceLabel: "Chrome",
            authenticationFailurePolicy: .stopFallback)
        let strategy = CursorAppTokenFetchStrategy(
            appAuthStore: CursorAppTokenStoreStub(session: CursorAppAuthSession(accessToken: token)),
            loadCachedEntry: { selectedEntry })

        #expect(await strategy.isAvailable(Self.makeContext(sourceMode: .auto)) == false)
        // An explicit oauth selection still uses the app token.
        #expect(await strategy.isAvailable(Self.makeContext(sourceMode: .oauth)))
    }

    @Test
    func `manual cookie source keeps winning auto mode`() async throws {
        let token = try makeCursorAppTokenJWT()
        let strategy = CursorAppTokenFetchStrategy(
            appAuthStore: CursorAppTokenStoreStub(session: CursorAppAuthSession(accessToken: token)),
            loadCachedEntry: { nil })
        let manualSettings = ProviderSettingsSnapshot.make(
            cursor: .init(cookieSource: .manual, manualCookieHeader: "WorkosCursorSessionToken=manual"))

        #expect(await strategy.isAvailable(Self.makeContext(sourceMode: .auto, settings: manualSettings)) == false)
        // An explicit oauth selection still uses the app token.
        #expect(await strategy.isAvailable(Self.makeContext(sourceMode: .oauth, settings: manualSettings)))

        // A manual source without a usable header cannot pin an account.
        let emptyManualSettings = ProviderSettingsSnapshot.make(
            cursor: .init(cookieSource: .manual, manualCookieHeader: "   "))
        #expect(await strategy.isAvailable(Self.makeContext(sourceMode: .auto, settings: emptyManualSettings)))
    }

    @Test
    func `unselected cached session does not block auto mode`() async throws {
        let token = try makeCursorAppTokenJWT()
        let importedEntry = CookieHeaderCache.Entry(
            cookieHeader: "WorkosCursorSessionToken=imported",
            storedAt: Date(),
            sourceLabel: "Chrome")
        let strategy = CursorAppTokenFetchStrategy(
            appAuthStore: CursorAppTokenStoreStub(session: CursorAppAuthSession(accessToken: token)),
            loadCachedEntry: { importedEntry })
        #expect(await strategy.isAvailable(Self.makeContext(sourceMode: .auto)))
    }

    @Test
    func `app token strategy only falls back in auto mode`() {
        let strategy = CursorAppTokenFetchStrategy(
            appAuthStore: CursorAppTokenStoreStub(session: nil),
            loadCachedEntry: { nil })
        let error = CursorStatusProbeError.notLoggedIn
        #expect(strategy.shouldFallback(on: error, context: Self.makeContext(sourceMode: .auto)))
        #expect(!strategy.shouldFallback(on: error, context: Self.makeContext(sourceMode: .oauth)))
    }

    private static func resolveStrategies(sourceMode: ProviderSourceMode) async -> [any ProviderFetchStrategy] {
        await CursorProviderDescriptor.descriptor.fetchPlan.pipeline
            .resolveStrategies(self.makeContext(sourceMode: sourceMode))
    }

    private static func makeContext(
        sourceMode: ProviderSourceMode,
        settings: ProviderSettingsSnapshot? = nil) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: CursorAppTokenStrategyStubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }
}
