import AppKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// FP-181 final-publication proof.
///
/// This test exercises the real CodexBar URLSession/ProviderHTTPClient production transport stack
/// and the bundled Hugging Face plugin. Synthetic contract-valid server responses are intercepted
/// by URLProtocol; this is deliberately not described as real Hugging Face transport or live
/// account proof. The fixture records only sanitized route and phase labels.
@MainActor
@Suite(.serialized)
struct HuggingFaceRealTransportFinalPublicationTests {
    @Test
    func `matched then mismatched synthetic principals publish through the final menu card`() async throws {
        let harness = HuggingFaceFinalPublicationHarness()
        HuggingFaceFinalPublicationURLProtocol.install(harness)
        defer { HuggingFaceFinalPublicationURLProtocol.clear() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HuggingFaceFinalPublicationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = ProviderHTTPClient(session: session)
        let identityService = HuggingFaceIdentityService(transport: client)
        let apiStrategy = ScriptFetchStrategy(
            id: "huggingface.js",
            provider: .huggingface,
            bundledPlugin: "huggingface",
            secretKey: HuggingFaceSettingsReader.tokenEnvironmentKey,
            sourceLabel: "api",
            transport: client,
            resolveSecret: { environment in
                HuggingFaceSettingsReader.token(environment: environment)
            },
            isEnabled: { _ in true })
        let webStrategy = HuggingFaceWebFetchStrategy(
            transport: client,
            resolveCookieHeader: { _ in harness.cookieHeader() })
        let autoStrategy = HuggingFaceAutoFetchStrategy(
            apiStrategy: apiStrategy,
            webStrategy: webStrategy,
            identityService: identityService)
        let fixture = try Self.makeFixture(strategy: autoStrategy)

        await fixture.store.refreshProvider(.huggingface)
        try await Self.assertMatchedPublication(
            fixture: fixture,
            identityService: identityService,
            harness: harness)

        harness.switchToMismatchedBrowserPrincipal()
        await fixture.store.refreshProvider(.huggingface)
        try await Self.assertMismatchedPublication(
            fixture: fixture,
            identityService: identityService,
            harness: harness)
    }

    private static func makeFixture(strategy: HuggingFaceAutoFetchStrategy) throws -> Fixture {
        let settings = testSettingsStore(
            suiteName: "HuggingFaceRealTransportFinalPublicationTests",
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings.huggingFaceCookieSource = .manual
        settings.huggingFaceManualCookieHeader = "session=browser-A"
        settings.addTokenAccount(
            provider: .huggingface,
            label: "API account A",
            token: "api-token-A")
        settings.setActiveTokenAccountIndex(0, for: .huggingface)
        let huggingFaceMetadata = try #require(ProviderDescriptorRegistry.metadata[.huggingface])
        settings.setProviderEnabled(
            provider: .huggingface,
            metadata: huggingFaceMetadata,
            enabled: true)

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let baseSpec = try #require(store.providerSpecs[.huggingface])
        let baseDescriptor = baseSpec.descriptor
        store.providerSpecs[.huggingface] = ProviderSpec(
            style: baseSpec.style,
            isEnabled: { true },
            descriptor: ProviderDescriptor(
                id: baseDescriptor.id,
                settingsSection: baseDescriptor.settingsSection,
                credentials: baseDescriptor.credentials,
                config: baseDescriptor.config,
                metadata: baseDescriptor.metadata,
                branding: baseDescriptor.branding,
                tokenCost: baseDescriptor.tokenCost,
                pace: baseDescriptor.pace,
                history: baseDescriptor.history,
                presentation: baseDescriptor.presentation,
                fetchPlan: ProviderFetchPlan(
                    sourceModes: [.auto, .api, .web],
                    pipeline: ProviderFetchPipeline { _ in [strategy] }),
                cli: baseDescriptor.cli),
            makeFetchContext: baseSpec.makeFetchContext)

        return Fixture(store: store, settings: settings)
    }

    private static func assertMatchedPublication(
        fixture: Fixture,
        identityService: HuggingFaceIdentityService,
        harness: HuggingFaceFinalPublicationHarness) async throws
    {
        let account = try #require(fixture.settings.effectiveSelectedTokenAccount(for: .huggingface))
        let accountSnapshots = try #require(fixture.store.accountSnapshots[.huggingface])
        let accountSnapshot = try #require(accountSnapshots.first)
        let liveSnapshot = try #require(fixture.store.snapshot(for: .huggingface))

        #expect(accountSnapshots.count == 1)
        #expect(accountSnapshot.account.id == account.id)
        #expect(accountSnapshot.sourceLabel == "api+web")
        #expect(accountSnapshot.snapshot?.providerCost?.used == 2.41)
        #expect(accountSnapshot.snapshot?.providerCost?.balance == 9.25)
        #expect(accountSnapshot.snapshot?.identity?.accountEmail == "api-a@example.invalid")
        #expect(liveSnapshot.providerCost?.balance == 9.25)
        #expect(fixture.store.lastSourceLabels[.huggingface] == "api+web")
        #expect(fixture.store.huggingFaceBrowserWallets[.huggingface] == nil)

        let cache = await identityService.cache
        #expect(cache.count == 2)
        #expect(harness.count(route: .apiBilling, phase: .matchedA) == 1)
        #expect(harness.count(route: .browserBilling, phase: .matchedA) == 1)
        #expect(harness.count(route: .bearerIdentity, phase: .matchedA) == 1)
        #expect(harness.count(route: .browserIdentity, phase: .matchedA) == 1)
    }

    private static func assertMismatchedPublication(
        fixture: Fixture,
        identityService: HuggingFaceIdentityService,
        harness: HuggingFaceFinalPublicationHarness) async throws
    {
        let accountSnapshots = try #require(fixture.store.accountSnapshots[.huggingface])
        let accountSnapshot = try #require(accountSnapshots.first)
        let liveSnapshot = try #require(fixture.store.snapshot(for: .huggingface))
        let publication = try #require(fixture.store.huggingFaceBrowserWallets[.huggingface])
        let controller = StatusItemController(
            store: fixture.store,
            settings: fixture.settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }
        let model = try #require(controller.menuCardModel(for: .huggingface))
        let walletSection = try #require(model.providerDetails.first { $0.title == "Browser session wallet" })

        #expect(accountSnapshots.count == 1)
        #expect(accountSnapshot.sourceLabel == "api")
        #expect(accountSnapshot.snapshot?.providerCost?.used == 2.41)
        #expect(accountSnapshot.snapshot?.providerCost?.balance == nil)
        #expect(accountSnapshot.snapshot?.identity?.accountEmail == "api-a@example.invalid")
        #expect(liveSnapshot.providerCost?.balance == nil)
        #expect(liveSnapshot.identity?.accountEmail == "api-a@example.invalid")
        #expect(fixture.store.lastSourceLabels[.huggingface] == "api")
        #expect(publication.balanceUSD == 42.50)
        #expect(publication.attribution == .unverified)
        #expect(walletSection.rows.map(\.value) == ["$42.50", "Unverified against this API token"])
        #expect(model.email == "api-a@example.invalid")
        #expect(model.providerCost?.title == "API spend")
        #expect(await identityService.cache.count == 3)
        #expect(harness.count(route: .apiBilling, phase: .mismatchedB) == 1)
        #expect(harness.count(route: .browserBilling, phase: .mismatchedB) == 1)
        #expect(harness.count(route: .browserIdentity, phase: .mismatchedB) == 1)
        // Bearer-A identity is served from the populated identity cache on phase B.
        #expect(harness.count(route: .bearerIdentity, phase: .mismatchedB) == 0)
    }

    private struct Fixture {
        let store: UsageStore
        let settings: SettingsStore
    }
}

private final class HuggingFaceFinalPublicationHarness: @unchecked Sendable {
    enum Phase: String, Sendable {
        case matchedA
        case mismatchedB
    }

    enum Route: String, Sendable {
        case apiBilling
        case browserBilling
        case bearerIdentity
        case browserIdentity
    }

    struct Event: Equatable, Sendable {
        let phase: Phase
        let route: Route
    }

    struct Response: Sendable {
        let body: Data
        let statusCode: Int
        let headers: [String: String]
    }

    private let lock = NSLock()
    private var phase: Phase = .matchedA
    private var events: [Event] = []

    func cookieHeader() -> String {
        self.lock.withLock {
            switch self.phase {
            case .matchedA: "session=browser-A"
            case .mismatchedB: "session=browser-B"
            }
        }
    }

    func switchToMismatchedBrowserPrincipal() {
        self.lock.withLock {
            self.phase = .mismatchedB
        }
    }

    func count(route: Route, phase: Phase) -> Int {
        self.lock.withLock { self.events.count { $0.route == route && $0.phase == phase } }
    }

    func response(for request: URLRequest) throws -> Response {
        guard let url = request.url, url.host?.lowercased() == "huggingface.co" else {
            throw URLError(.badURL)
        }
        let currentPhase = self.lock.withLock { self.phase }
        switch url.path {
        case "/api/settings/billing/usage":
            guard request.value(forHTTPHeaderField: "Authorization") != nil else {
                throw URLError(.userAuthenticationRequired)
            }
            self.record(route: .apiBilling, phase: currentPhase)
            return Self.jsonResponse(Self.billingBody)
        case "/api/whoami-v2":
            if request.value(forHTTPHeaderField: "Authorization") != nil {
                self.record(route: .bearerIdentity, phase: currentPhase)
                return Self.jsonResponse(Self.apiIdentityBody)
            }
            guard let cookie = request.value(forHTTPHeaderField: "Cookie") else {
                throw URLError(.userAuthenticationRequired)
            }
            self.record(route: .browserIdentity, phase: currentPhase)
            let body = cookie.contains("browser-B") ? Self.browserBIdentityBody : Self.apiIdentityBody
            return Self.jsonResponse(body)
        case "/settings/billing":
            guard let cookie = request.value(forHTTPHeaderField: "Cookie") else {
                throw URLError(.userAuthenticationRequired)
            }
            self.record(route: .browserBilling, phase: currentPhase)
            let balance = cookie.contains("browser-B") ? "42.5" : "9.25"
            return Self.htmlResponse(Self.billingPage(balanceUSD: balance))
        default:
            throw URLError(.resourceUnavailable)
        }
    }

    private func record(route: Route, phase: Phase) {
        self.lock.withLock {
            self.events.append(Event(phase: phase, route: route))
        }
    }

    private static let billingBody = """
    {
      "period": {
        "periodStart": "2026-08-01T00:00:00Z",
        "periodEnd": "2026-09-01T00:00:00Z"
      },
      "usage": {
        "endpoints": [{"totalCostMicroUSD": 2410000}],
        "spaces": []
      }
    }
    """

    private static let apiIdentityBody = """
    {"type":"user","id":"opaque-api-a","name":"api-a","email":"api-a@example.invalid","isPro":true}
    """

    private static let browserBIdentityBody = """
    {"type":"user","id":"opaque-principal-b","name":"browser-b","email":"browser-b@example.invalid","isPro":false}
    """

    private static func billingPage(balanceUSD: String) -> String {
        "<html><body><div data-props='{\"entity\":{\"type\":\"user\",\"currentBalanceUsd\":\(balanceUSD)}}'>"
            + "</div></body></html>"
    }

    private static func jsonResponse(_ body: String) -> Response {
        Response(
            body: Data(body.utf8),
            statusCode: 200,
            headers: ["Content-Type": "application/json"])
    }

    private static func htmlResponse(_ body: String) -> Response {
        Response(
            body: Data(body.utf8),
            statusCode: 200,
            headers: ["Content-Type": "text/html; charset=utf-8"])
    }
}

private final class HuggingFaceFinalPublicationURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var activeHarness: HuggingFaceFinalPublicationHarness?

    static func install(_ harness: HuggingFaceFinalPublicationHarness) {
        self.lock.withLock {
            self.activeHarness = harness
        }
    }

    static func clear() {
        self.lock.withLock {
            self.activeHarness = nil
        }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.lowercased() == "huggingface.co"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let harness = Self.lock.withLock({ Self.activeHarness }) else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        do {
            let response = try harness.response(for: self.request)
            guard let url = self.request.url,
                  let httpResponse = HTTPURLResponse(
                      url: url,
                      statusCode: response.statusCode,
                      httpVersion: "HTTP/1.1",
                      headerFields: response.headers)
            else {
                throw URLError(.badServerResponse)
            }
            self.client?.urlProtocol(
                self,
                didReceive: httpResponse,
                cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: response.body)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
