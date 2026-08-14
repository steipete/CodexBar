import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite(.serialized)
struct GrokCreditsProxyFetcherTests {
    @Test
    func `constructs the CLI proxy request and parses weekly credits`() async throws {
        let session = Self.makeSession()
        let endpoint = try #require(URL(string: "https://grok.test/v1/billing?format=credits"))
        defer { GrokCreditsProxyStubURLProtocol.reset() }
        GrokCreditsProxyStubURLProtocol.reset()
        GrokCreditsProxyStubURLProtocol.handler = { request in
            #expect(request.url == endpoint)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-123")
            #expect(request.value(forHTTPHeaderField: "x-xai-token-auth") == "xai-grok-cli")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "CodexBar")
            #expect(request.timeoutInterval == 15)
            return try Self.response(
                for: request,
                body: """
                {
                  "config": {
                    "creditUsagePercent": 12.5,
                    "currentPeriod": {
                      "type": "USAGE_PERIOD_TYPE_WEEKLY",
                      "start": "2026-08-06T00:00:00Z",
                      "end": "2026-08-13T00:00:00Z"
                    },
                    "billingPeriodEnd": "2026-08-13T00:00:00Z",
                    "onDemandCap": { "val": 1000 },
                    "onDemandUsed": { "val": 250 }
                  }
                }
                """)
        }

        let snapshot = try await GrokCreditsProxyFetcher.fetch(
            credentials: Self.credentials,
            session: session,
            endpoint: endpoint)
        let expectedReset = try Self.date("2026-08-13T00:00:00Z")

        #expect(GrokCreditsProxyStubURLProtocol.requests.count == 1)
        #expect(snapshot.usedPercent == 12.5)
        #expect(snapshot.resetsAt == expectedReset)
    }

    @Test
    func `derives percent from on demand cap and usage`() throws {
        let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
        {
          "config": {
            "onDemandCap": { "val": 1000.0 },
            "onDemandUsed": { "val": 250.5 }
          }
        }
        """.utf8))

        #expect(snapshot.usedPercent == 25.05)
        #expect(snapshot.resetsAt == nil)
    }

    @Test
    func `clamps an out of range credit usage percent`() throws {
        let over = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
        {
          "config": {
            "creditUsagePercent": 104.2,
            "billingPeriodEnd": "2026-08-13T00:00:00Z"
          }
        }
        """.utf8))
        let under = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
        {
          "config": { "creditUsagePercent": -3.5 }
        }
        """.utf8))

        #expect(over.usedPercent == 100)
        #expect(try over.resetsAt == (Self.date("2026-08-13T00:00:00Z")))
        #expect(under.usedPercent == 0)
    }

    @Test
    func `treats a period without usage as zero percent`() throws {
        let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
        {
          "config": {
            "currentPeriod": { "end": "2026-08-13T00:00:00.123Z" },
            "billingPeriodEnd": "2026-08-14T00:00:00Z"
          }
        }
        """.utf8))
        let expectedReset = try Self.date("2026-08-13T00:00:00.123Z")

        #expect(snapshot.usedPercent == 0)
        #expect(snapshot.resetsAt == expectedReset)
    }

    @Test
    func `rejects a response without usage or a period`() {
        #expect {
            _ = try GrokCreditsProxyFetcher.parseSnapshot(Data(#"{"config":{}}"#.utf8))
        } throws: { error in
            guard case GrokWebBillingError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `uses billing period end when current period end is missing`() throws {
        let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
        {
          "config": {
            "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY" },
            "billingPeriodEnd": "2026-08-13T00:00:00Z"
          }
        }
        """.utf8))
        let expectedReset = try Self.date("2026-08-13T00:00:00Z")

        #expect(snapshot.usedPercent == 0)
        #expect(snapshot.resetsAt == expectedReset)
    }

    @Test
    func `unauthorized proxy response asks for grok login`() async throws {
        let session = Self.makeSession()
        let endpoint = try #require(URL(string: "https://grok.test/v1/billing?format=credits"))
        defer { GrokCreditsProxyStubURLProtocol.reset() }
        GrokCreditsProxyStubURLProtocol.reset()
        GrokCreditsProxyStubURLProtocol.handler = { request in
            try Self.response(for: request, statusCode: 401, body: "unauthorized")
        }

        await #expect {
            _ = try await GrokCreditsProxyFetcher.fetch(
                credentials: Self.credentials,
                session: session,
                endpoint: endpoint)
        } throws: { error in
            error.localizedDescription.contains("grok login")
        }
    }

    @Test
    func `expired credentials fail before making a request`() async throws {
        let session = Self.makeSession()
        let endpoint = try #require(URL(string: "https://grok.test/v1/billing?format=credits"))
        defer { GrokCreditsProxyStubURLProtocol.reset() }
        GrokCreditsProxyStubURLProtocol.reset()

        await #expect {
            _ = try await GrokCreditsProxyFetcher.fetch(
                credentials: Self.expiredCredentials,
                session: session,
                endpoint: endpoint)
        } throws: { error in
            guard case GrokWebBillingError.missingCredentials = error else { return false }
            return true
        }
        #expect(GrokCreditsProxyStubURLProtocol.requests.isEmpty)
    }

    @Test
    func `recognizes WKE credential rejection and gives CLI-only guidance`() {
        let message = "No credentials presented. [WKE=unauthenticated:no-credentials]"

        #expect(GrokWebBillingError.isWebKeyExchangeCredentialRejection(status: 16, message: message))
        #expect(!GrokWebBillingError.isWebKeyExchangeCredentialRejection(status: 7, message: message))
        #expect(!GrokWebBillingError.isWebKeyExchangeCredentialRejection(status: 16, message: "token expired"))

        let description = GrokWebBillingError.rpcFailed(16, message).localizedDescription
        #expect(description.contains("grok login"))
        #expect(!description.contains("Chrome"))
        #expect(GrokWebBillingError.isAuthenticationFailure(status: 16, message: message))
    }

    @Test
    func `proxy success short circuits legacy web billing`() async throws {
        let events = EventRecorder()
        let result = try await GrokWebFetchStrategy.fetchProxyFirst(
            credentials: Self.credentials,
            proxyBilling: { _ in
                events.append("proxy")
                return GrokWebBillingSnapshot(usedPercent: 12.5, resetsAt: nil)
            },
            legacyBilling: {
                events.append("legacy")
                return (GrokWebBillingSnapshot(usedPercent: 99, resetsAt: nil), "legacy", false)
            })

        #expect(events.values == ["proxy"])
        #expect(result.snapshot.usedPercent == 12.5)
        #expect(result.sourceLabel == "grok-cli-proxy")
        #expect(result.authenticatedByAuthFile)
    }

    @Test
    func `proxy failure falls through to legacy web billing`() async throws {
        let events = EventRecorder()
        let result = try await GrokWebFetchStrategy.fetchProxyFirst(
            credentials: Self.credentials,
            proxyBilling: { _ in
                events.append("proxy")
                throw URLError(.cannotConnectToHost)
            },
            legacyBilling: {
                events.append("legacy")
                return (GrokWebBillingSnapshot(usedPercent: 42, resetsAt: nil), "Chrome", false)
            })

        #expect(events.values == ["proxy", "legacy"])
        #expect(result.snapshot.usedPercent == 42)
        #expect(result.sourceLabel == "Chrome")
        #expect(!result.authenticatedByAuthFile)
    }

    @Test
    func `proxy cancellation does not fall through to legacy web billing`() async throws {
        let events = EventRecorder()

        await #expect {
            _ = try await GrokWebFetchStrategy.fetchProxyFirst(
                credentials: Self.credentials,
                proxyBilling: { _ in
                    events.append("proxy")
                    throw CancellationError()
                },
                legacyBilling: {
                    events.append("legacy")
                    return (GrokWebBillingSnapshot(usedPercent: 42, resetsAt: nil), "Chrome", false)
                })
        } throws: { error in
            error is CancellationError
        }

        await #expect {
            _ = try await GrokWebFetchStrategy.fetchProxyFirst(
                credentials: Self.credentials,
                proxyBilling: { _ in
                    events.append("proxy")
                    throw URLError(.cancelled)
                },
                legacyBilling: {
                    events.append("legacy")
                    return (GrokWebBillingSnapshot(usedPercent: 42, resetsAt: nil), "Chrome", false)
                })
        } throws: { error in
            (error as? URLError)?.code == .cancelled
        }

        #expect(events.values == ["proxy", "proxy"])
    }

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
        expiresAt: .distantPast,
        createTime: nil)

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrokCreditsProxyStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int = 200,
        body: String) throws -> (HTTPURLResponse, Data)
    {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (response, Data(body.utf8))
    }

    private static func date(_ raw: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return try #require(formatter.date(from: raw))
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }

    func append(_ value: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storage.append(value)
    }
}

private final class GrokCreditsProxyStubURLProtocol: URLProtocol {
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
