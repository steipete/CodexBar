import Foundation
import Testing
@testable import CodexBarCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite(.serialized)
struct GrokRemainingResetsFetcherTests {
    @Test
    func `parses a redacted remaining-reset frame captured from grok.com`() throws {
        let now = Date(timeIntervalSince1970: 1_787_647_576)
        let tokens = try GrokRemainingResetsFetcher.parseTokens(Self.liveFrame, now: now)

        #expect(tokens.count == 1)
        #expect(tokens[0].tokenID == "restok_sample")
        #expect(tokens[0].grantedAt == Date(timeIntervalSince1970: 1_786_560_540))
        #expect(tokens[0].expiresAt == Date(timeIntervalSince1970: 1_789_238_940))
    }

    @Test
    func `drops an expired remaining-reset token`() throws {
        let now = Date(timeIntervalSince1970: 1_789_238_941)
        let tokens = try GrokRemainingResetsFetcher.parseTokens(Self.liveFrame, now: now)
        #expect(tokens.isEmpty)
    }

    @Test
    func `maps available inventory onto Limit Reset Credits`() {
        let now = Date(timeIntervalSince1970: 1_787_647_576)
        let sections = GrokRemainingResetsFetcher.detailSections(
            tokens: [
                GrokRemainingReset(
                    tokenID: "restok_sample",
                    grantedAt: Date(timeIntervalSince1970: 1_786_560_540),
                    expiresAt: Date(timeIntervalSince1970: 1_789_238_940)),
            ],
            now: now)

        #expect(sections.count == 1)
        #expect(sections[0].rows.count == 1)
        #expect(sections[0].rows[0].label == "Limit Reset Credits")
        #expect(sections[0].rows[0].value == "1 available")
        #expect(sections[0].rows[0].secondaryValue?.hasPrefix("Expires ") == true)
    }

    @Test
    func `hides remaining resets when none are still valid`() {
        let now = Date(timeIntervalSince1970: 1_789_238_941)
        let sections = GrokRemainingResetsFetcher.detailSections(
            tokens: [
                GrokRemainingReset(
                    tokenID: "restok_sample",
                    grantedAt: Date(timeIntervalSince1970: 1_786_560_540),
                    expiresAt: Date(timeIntervalSince1970: 1_789_238_940)),
            ],
            now: now)
        #expect(sections.isEmpty)
    }

    @Test
    func `display snapshot keeps only available expirations in order`() throws {
        let now = Date(timeIntervalSince1970: 1_787_647_576)
        let later = now.addingTimeInterval(7200)
        let sooner = now.addingTimeInterval(3600)
        let snapshot = try #require(GrokRemainingResetsFetcher.snapshot(
            tokens: [
                GrokRemainingReset(tokenID: "later", grantedAt: nil, expiresAt: later),
                GrokRemainingReset(tokenID: "", grantedAt: nil, expiresAt: sooner),
                GrokRemainingReset(tokenID: "expired", grantedAt: nil, expiresAt: now),
                GrokRemainingReset(tokenID: "sooner", grantedAt: nil, expiresAt: sooner),
            ],
            now: now))

        #expect(snapshot.expirations == [sooner, later])
        #expect(snapshot.updatedAt == now)
    }

    @Test
    func `usage snapshot does not persist live Grok reset inventory`() throws {
        let now = Date(timeIntervalSince1970: 1_787_647_576)
        let resetCredits = GrokRateLimitResetCreditsSnapshot(
            expirations: [now.addingTimeInterval(3600)],
            updatedAt: now)
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            grokResetCredits: resetCredits,
            updatedAt: now)
        let replaced = usage.replacing(details: .value([]))

        #expect(replaced.grokResetCredits == resetCredits)

        let data = try JSONEncoder().encode(replaced)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)

        #expect(json["grokResetCredits"] == nil)
        #expect(decoded.grokResetCredits == nil)
    }

    @Test
    func `constructs the remaining-resets request and keeps weekly usage on timeout`() async throws {
        let session = Self.makeSession()
        let endpoint = try #require(URL(string: "https://grok.test/prod_mc_billing.ConsumerUiSvc/GetRemainingResets"))
        defer { GrokRemainingResetsStubURLProtocol.reset() }
        GrokRemainingResetsStubURLProtocol.reset()
        GrokRemainingResetsStubURLProtocol.handler = { request in
            #expect(request.url == endpoint)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-123")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/grpc-web+proto")
            #expect(request.value(forHTTPHeaderField: "x-grpc-web") == "1")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "CodexBar")
            #expect(request.timeoutInterval == 2)
            return try Self.response(for: request, body: Self.liveFrame)
        }

        let tokens = await GrokRemainingResetsFetcher.fetch(
            credentials: Self.credentials,
            cookieHeader: nil,
            now: Date(timeIntervalSince1970: 1_787_647_576),
            session: session,
            endpoint: endpoint)

        #expect(GrokRemainingResetsStubURLProtocol.requests.count == 1)
        #expect(tokens.count == 1)
        #expect(tokens[0].tokenID == "restok_sample")
    }

    @Test
    func `skips remaining resets when credentials are expired and no cookie is present`() async {
        let tokens = await GrokRemainingResetsFetcher.fetch(
            credentials: Self.expiredCredentials,
            cookieHeader: nil)
        #expect(tokens.isEmpty)
    }

    @Test
    func `usage snapshot keeps weekly credits when remaining resets are empty`() {
        let snapshot = GrokUsageSnapshot(
            billing: nil,
            webBilling: GrokWebBillingSnapshot(
                usedPercent: 29,
                resetsAt: Date(timeIntervalSince1970: 1_788_113_219)),
            credentials: Self.credentials,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: Date(timeIntervalSince1970: 1_787_647_576))
        let usage = snapshot.toUsageSnapshot().replacing(
            details: .value(GrokRemainingResetsFetcher.detailSections(tokens: [], now: snapshot.updatedAt)))

        #expect(usage.primary?.usedPercent == 29)
        #expect(usage.details.isEmpty)
    }

    @Test
    func `cached lookup returns weekly usage without waiting for refresh`() async throws {
        GrokRemainingResetsFetcher.resetCacheForTesting()
        defer { GrokRemainingResetsFetcher.resetCacheForTesting() }
        let now = Date(timeIntervalSince1970: 1_787_647_576)
        let token = GrokRemainingReset(
            tokenID: "restok_sample",
            grantedAt: nil,
            expiresAt: now.addingTimeInterval(86400))

        let startedAt = ContinuousClock.now
        let first = GrokRemainingResetsFetcher.cachedTokensAndRefresh(
            credentials: Self.credentials,
            cookieHeader: nil,
            now: now,
            refresh: { _, _, _ in
                try? await Task.sleep(for: .milliseconds(200))
                return [token]
            })
        let elapsed = ContinuousClock.now - startedAt

        #expect(first.isEmpty)
        #expect(elapsed < .milliseconds(100))

        try await Task.sleep(for: .milliseconds(250))
        let second = GrokRemainingResetsFetcher.cachedTokensAndRefresh(
            credentials: Self.credentials,
            cookieHeader: nil,
            now: now.addingTimeInterval(1),
            refresh: { _, _, _ in nil })
        #expect(second == [token])
    }

    @Test
    func `deferred lookup publishes a display snapshot after returning cached usage`() async throws {
        GrokRemainingResetsFetcher.resetCacheForTesting()
        defer { GrokRemainingResetsFetcher.resetCacheForTesting() }
        let now = Date(timeIntervalSince1970: 1_787_647_576)
        let expiresAt = now.addingTimeInterval(86400)
        let token = GrokRemainingReset(
            tokenID: "restok_sample",
            grantedAt: nil,
            expiresAt: expiresAt)

        let startedAt = ContinuousClock.now
        let lookup = GrokRemainingResetsFetcher.cachedLookupAndRefresh(
            credentials: Self.credentials,
            cookieHeader: nil,
            now: now,
            refresh: { _, _, _ in
                try? await Task.sleep(for: .milliseconds(100))
                return [token]
            })
        let elapsed = ContinuousClock.now - startedAt

        #expect(lookup.tokens.isEmpty)
        #expect(elapsed < .milliseconds(50))

        let task = try #require(lookup.snapshotTask)
        let snapshot = try #require(await task.value)
        #expect(snapshot.expirations == [expiresAt])
        #expect(snapshot.updatedAt == now)
    }

    @Test
    func `CLI coupon lookup uses the credential captured in its snapshot`() {
        let now = Date(timeIntervalSince1970: 1_787_647_576)
        let snapshot = GrokUsageSnapshot(
            billing: nil,
            webBilling: GrokWebBillingSnapshot(usedPercent: 29, resetsAt: nil),
            credentials: Self.credentials,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: now)
        let capturedToken = LockIsolated<String?>(nil)

        _ = GrokCLIFetchStrategy.remainingResetTokens(
            snapshot: snapshot,
            includeOptionalUsage: true,
            lookup: { credentials, _, _ in
                capturedToken.setValue(credentials?.accessToken)
                return .empty
            })

        #expect(capturedToken.value == Self.credentials.accessToken)
    }

    @Test
    func `CLI coupon lookup is skipped when optional usage is disabled`() {
        let snapshot = GrokUsageSnapshot(
            billing: nil,
            webBilling: GrokWebBillingSnapshot(usedPercent: 29, resetsAt: nil),
            credentials: Self.credentials,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: Date(timeIntervalSince1970: 1_787_647_576))
        let lookupCalled = LockIsolated(false)

        let tokens = GrokCLIFetchStrategy.remainingResetTokens(
            snapshot: snapshot,
            includeOptionalUsage: false,
            lookup: { _, _, _ in
                lookupCalled.setValue(true)
                return .empty
            })

        #expect(tokens.isEmpty)
        #expect(!lookupCalled.value)
    }

    private static let liveFrame = Data(
        hex: "00000000235221520d726573746f6b5f73616d706c65"
            + "a20106089c80f3d306f20106089cbd96d506"
            + "800000000f677270632d7374617475733a300d0a")

    private static let credentials = GrokCredentials(
        accessToken: "token-123",
        refreshToken: "refresh-123",
        scope: "https://auth.x.ai::client",
        authMode: "oidc",
        userId: "user-123",
        email: "grok@example.com",
        firstName: "G",
        lastName: "Rok",
        teamId: "team-123",
        oidcIssuer: "https://auth.x.ai",
        oidcClientId: "client",
        expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
        createTime: Date(timeIntervalSince1970: 1_799_000_000))

    private static let expiredCredentials = GrokCredentials(
        accessToken: "expired-token",
        refreshToken: nil,
        scope: "https://auth.x.ai::client",
        authMode: "oidc",
        userId: nil,
        email: nil,
        firstName: nil,
        lastName: nil,
        teamId: nil,
        oidcIssuer: nil,
        oidcClientId: nil,
        expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
        createTime: Date(timeIntervalSince1970: 1_699_000_000))

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrokRemainingResetsStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(for request: URLRequest, body: Data) throws -> (HTTPURLResponse, Data) {
        let url = try #require(request.url)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/grpc-web+proto"])!
        return (response, body)
    }
}

private final class GrokRemainingResetsStubURLProtocol: URLProtocol {
    private static let state = State()

    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { Self.state.handler }
        set { Self.state.handler = newValue }
    }

    static var requests: [URLRequest] {
        state.requests
    }

    static func reset() {
        self.state.reset()
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.record(self.request)
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

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var storedHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
        private var storedRequests: [URLRequest] = []

        var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
            get {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.storedHandler
            }
            set {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.storedHandler = newValue
            }
        }

        var requests: [URLRequest] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.storedRequests
        }

        func record(_ request: URLRequest) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.storedRequests.append(request)
        }

        func reset() {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.storedHandler = nil
            self.storedRequests = []
        }
    }
}

extension Data {
    fileprivate init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
