import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized, ClaudeOAuthDefaultsFixtures(), ProviderTransportRegressionFixtures())
@MainActor
struct CursorTransportIdentityTests {
    enum Route: CaseIterable, Sendable {
        case app
        case stored
    }

    @Test(arguments: Route.allCases, ProviderTransportRegressionSupport.codes)
    func `resolved Cursor sessions retain required summary transport errors`(
        route: Route,
        code: URLError.Code) async throws
    {
        let (error, transport) = try await Self.failure(
            route: route, underlying: ProviderTransportRegressionSupport.urlError(code))
        ProviderTransportRegressionSupport.expectPolicy(
            error, code: code, description: "Cursor API error: Verbindung fehlgeschlagen")
        #expect((error as NSError).userInfo["fixture-marker"] as? String == "preserved")
        let required = await transport.requests().filter { $0.url?.path == "/api/usage-summary" }
        #expect(required.count == 1)
        if route == .stored {
            #expect(required.first?.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=fixture-stored")
        }
    }

    @Test(arguments: Route.allCases)
    func `Cursor task cancellation remains typed`(route: Route) async throws {
        let (error, _) = try await Self.failure(route: route, underlying: CancellationError())
        #expect(error is CancellationError)
        ProviderTransportRegressionSupport.expectPolicy(error, code: .cancelled)
    }

    @Test(arguments: Route.allCases, [URLError.Code.badURL, .secureConnectionFailed])
    func `Cursor does not broaden URL error retention`(route: Route, code: URLError.Code) async throws {
        let (error, _) = try await Self.failure(
            route: route,
            underlying: ProviderTransportRegressionSupport.urlError(code))
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
        #expect(!UsageStore.isStartupConnectivityRetryableError(error))
        #expect(UsageStore.refreshFailureHookStatus(error) == "network_error")
    }

    @Test(arguments: Route.allCases, [true, false])
    func `two Cursor outages retain only existing quota and widget samples`(
        route: Route,
        hasPriorData: Bool) async throws
    {
        let (error, _) = try await Self.failure(route: route, underlying: ProviderTransportRegressionSupport.urlError())
        try await ProviderTransportRegressionSupport.withStore(
            provider: .cursor,
            hasPriorData: hasPriorData)
        { store, prior in
            var saved: WidgetSnapshot?
            store._test_widgetSnapshotSaveOverride = { saved = $0 }
            store.persistWidgetSnapshot(reason: "cursor-transport-before")
            await store.widgetSnapshotPersistTask?.value
            let before = saved?.entries.first { $0.provider == .cursor }
            #expect((before != nil) == hasPriorData)
            var fetches = 0
            store._test_providerFetchOutcomeOverride = { _ in
                fetches += 1
                return ProviderFetchOutcome(result: .failure(error), attempts: [])
            }
            await store.refreshProvider(.cursor, allowDisabled: true)
            await store.refreshProvider(.cursor, allowDisabled: true)
            #expect(fetches == 2)
            #expect(store.errors[.cursor] == error.localizedDescription)
            #expect((store.snapshot(for: .cursor) != nil) == hasPriorData)
            store.persistWidgetSnapshot(reason: "cursor-transport-after")
            await store.widgetSnapshotPersistTask?.value
            let after = saved?.entries.first { $0.provider == .cursor }
            #expect((after != nil) == hasPriorData)
            if hasPriorData {
                #expect(store.snapshot(for: .cursor)?.primary == prior.primary)
                #expect(store.snapshot(for: .cursor)?.secondary == prior.secondary)
                #expect(store.snapshot(for: .cursor)?.identity?.accountEmail == prior.identity?.accountEmail)
                #expect(store.snapshot(for: .cursor)?.updatedAt == prior.updatedAt)
                #expect(after?.primary == before?.primary)
                #expect(after?.secondary == before?.secondary)
                #expect(after?.updatedAt == prior.updatedAt)
            }
        }
    }

    @Test(arguments: Route.allCases, [401, 500])
    func `Cursor HTTP rejection still removes prior quota and widget samples`(
        route: Route,
        statusCode: Int) async throws
    {
        let (error, _) = try await Self.failure(route: route, statusCode: statusCode)
        #expect(error is CursorStatusProbeError)
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
        #expect(!UsageStore.isStartupConnectivityRetryableError(error))
        try await ProviderTransportRegressionSupport.withStore(provider: .cursor) { store, _ in
            var saved: WidgetSnapshot?
            store._test_widgetSnapshotSaveOverride = { saved = $0 }
            store
                ._test_providerFetchOutcomeOverride = { _ in
                    ProviderFetchOutcome(result: .failure(error), attempts: [])
                }
            await store.refreshProvider(.cursor, allowDisabled: true)
            await store.refreshProvider(.cursor, allowDisabled: true)
            #expect(store.snapshot(for: .cursor) == nil)
            store.persistWidgetSnapshot(reason: "cursor-auth-rejection")
            await store.widgetSnapshotPersistTask?.value
            #expect(saved?.entries.contains { $0.provider == .cursor } == false)
        }
    }

    @Test
    func `synthetic Cursor session changes remain terminal`() {
        let error = CursorStatusProbeError.networkError("Cursor session changed during refresh")
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
        #expect(!UsageStore.isStartupConnectivityRetryableError(error))
        #expect(UsageStore.refreshFailureHookStatus(error) == "error")
    }

    private static func failure(
        route: Route,
        underlying: Error? = nil,
        statusCode: Int = 500) async throws -> (Error, ProviderHTTPTransportStub)
    {
        let root = ProviderTransportRegressionFixtures.root
        let sessionStore = CursorSessionStore(fileURL: root.appendingPathComponent("cursor-session.json"))
        CookieHeaderCache.clear(provider: .cursor)
        let appSession: CursorAppAuthSession?
        if route == .app {
            let token = try makeCursorAppAuthToken(
                subject: "user_transport_fixture",
                email: "fixture@example.test",
                expiration: Date().addingTimeInterval(3600))
            appSession = CursorAppAuthSession(accessToken: token)
        } else {
            appSession = nil
            let cookie = try #require(HTTPCookie(properties: [
                .domain: "cursor-web.test", .path: "/",
                .name: "WorkosCursorSessionToken", .value: "fixture-stored",
            ]))
            await sessionStore.setCookies([cookie])
        }
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path == "/api/usage-summary", let underlying { throw underlying }
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: url.path == "/api/usage-summary" ? statusCode : 404,
                httpVersion: nil,
                headerFields: nil))
            return (Data("{}".utf8), response)
        }
        let probe = try CursorStatusProbe(
            baseURL: #require(URL(string: "https://cursor-web.test")),
            browserDetection: ProviderTransportRegressionSupport.browser(root: root),
            browserCookieImportOrder: [],
            urlSession: transport,
            appAuthStore: CursorAppAuthSessionProviderStub(session: appSession),
            sessionStore: sessionStore,
            persistAppAuthSession: { _ in },
            conditionalMutationCoordinator: CookieHeaderCache.ConditionalMutationCoordinator())
        let error = await ProviderTransportRegressionSupport.captureFailure {
            _ = try await probe.fetch(allowCachedSessions: route == .stored, allowAppAuthFallback: route == .app)
        }
        await sessionStore.clearCookies()
        CookieHeaderCache.clear(provider: .cursor)
        return (error, transport)
    }
}
