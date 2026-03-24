import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct MiMoProviderTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    @Test
    func `cookie header normalizer keeps required mimo cookies`() {
        let raw = """
        curl 'https://platform.xiaomimimo.com/api/v1/balance' \
          -H 'Cookie: userId=123; api-platform_serviceToken=svc-token; ignored=value; api-platform_ph=ph-token'
        """

        let normalized = MiMoCookieHeader.normalizedHeader(from: raw)

        #expect(normalized == "api-platform_ph=ph-token; api-platform_serviceToken=svc-token; userId=123")
    }

    @Test
    func `cookie header normalizer rejects missing auth cookies`() {
        let normalized = MiMoCookieHeader.normalizedHeader(from: "Cookie: userId=123")

        #expect(normalized == nil)
    }

    @Test
    func `usage snapshot exposes balance through identity plan text`() {
        let snapshot = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            updatedAt: Date(timeIntervalSince1970: 1_742_771_200))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.loginMethod(for: .mimo) == "Balance: $25.51")
    }

    @Test
    func `parses balance payload`() throws {
        let now = Date(timeIntervalSince1970: 1_742_771_200)
        let json = """
        {
          "code": 0,
          "message": "",
          "data": {
            "balance": "25.51",
            "frozenBalance": null,
            "currency": "USD",
            "overdraftLimit": null
          }
        }
        """

        let snapshot = try MiMoUsageFetcher.parseUsageSnapshot(from: Data(json.utf8), now: now)

        #expect(snapshot.balance == 25.51)
        #expect(snapshot.currency == "USD")
        #expect(snapshot.updatedAt == now)
    }

    @Test
    func `fetch usage hits mimo balance endpoint with browser headers`() async throws {
        let registered = URLProtocol.registerClass(MiMoStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(MiMoStubURLProtocol.self)
            }
            MiMoStubURLProtocol.handler = nil
        }

        MiMoStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path == "/api/v1/balance")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "api-platform_serviceToken=svc-token; userId=123")
            #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9")
            #expect(request.value(forHTTPHeaderField: "x-timeZone") == "UTC+01:00")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://platform.xiaomimimo.com/#/console/balance")
            let body = """
            {
              "code": 0,
              "message": "",
              "data": {
                "balance": "25.51",
                "currency": "USD"
              }
            }
            """
            return Self.makeResponse(url: url, body: body)
        }

        let snapshot = try await MiMoUsageFetcher.fetchUsage(
            cookieHeader: "Cookie: userId=123; api-platform_serviceToken=svc-token",
            environment: ["MIMO_API_URL": "https://mimo.test/api/v1"],
            now: Date(timeIntervalSince1970: 1_742_771_200))

        #expect(snapshot.balance == 25.51)
        #expect(snapshot.currency == "USD")
    }

    @Test
    @MainActor
    func `provider detail plan row formats mimo as balance`() {
        let row = ProviderDetailView.planRow(provider: .mimo, planText: "Balance: $25.51")

        #expect(row?.label == "Balance")
        #expect(row?.value == "$25.51")
    }

    @Test(arguments: [UsageProvider.openrouter, .mimo])
    @MainActor
    func `menu descriptor renders balance providers without duplicate prefix`(provider: UsageProvider) throws {
        let suite = "MiMoProviderTests-menu-balance-\(provider.rawValue)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(self.makeBalanceSnapshot(provider: provider), provider: provider)

        let descriptor = MenuDescriptor.build(
            provider: provider,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)

        let lines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(lines.contains("Balance: $25.51"))
        #expect(!lines.contains("Balance: Balance: $25.51"))
    }

    @Test
    func `mimo web strategy unavailable when cookie source is off`() async {
        CookieHeaderCache.store(
            provider: .mimo,
            cookieHeader: "api-platform_serviceToken=svc-token; userId=123",
            sourceLabel: "cached")
        defer { CookieHeaderCache.clear(provider: .mimo) }

        let strategy = MiMoWebFetchStrategy()
        let context = self.makeContext(settings: ProviderSettingsSnapshot.make(
            mimo: ProviderSettingsSnapshot.MiMoProviderSettings(
                cookieSource: .off,
                manualCookieHeader: nil)))

        let available = await strategy.isAvailable(context)

        #expect(available == false)
    }

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int = 200) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }

    private func makeBalanceSnapshot(provider: UsageProvider) -> UsageSnapshot {
        let updatedAt = Date(timeIntervalSince1970: 1_742_771_200)
        switch provider {
        case .openrouter:
            return OpenRouterUsageSnapshot(
                totalCredits: 50,
                totalUsage: 24.49,
                balance: 25.51,
                usedPercent: 49,
                keyDataFetched: false,
                keyLimit: nil,
                keyUsage: nil,
                rateLimit: nil,
                updatedAt: updatedAt).toUsageSnapshot()
        case .mimo:
            return MiMoUsageSnapshot(
                balance: 25.51,
                currency: "USD",
                updatedAt: updatedAt).toUsageSnapshot()
        default:
            Issue.record("Unexpected provider \(provider.rawValue)")
            return UsageSnapshot(
                primary: nil,
                secondary: nil,
                tertiary: nil,
                updatedAt: updatedAt)
        }
    }

    private func makeContext(settings: ProviderSettingsSnapshot? = nil) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: browserDetection)
    }
}

final class MiMoStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mimo.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
