import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite(.serialized)
struct CodexOAuthRequestTests {
    @Test
    func `authenticated transport disables shared network state`() {
        let configuration = CodexAuthenticatedHTTPTransport.makeConfiguration()

        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCredentialStorage == nil)
    }

    @Test
    func `usage requests fetch distinct cacheable responses for each account`() async throws {
        defer { CodexOAuthAccountURLProtocol.reset() }
        CodexOAuthAccountURLProtocol.reset()

        let configuration = CodexAuthenticatedHTTPTransport.makeConfiguration()
        configuration.protocolClasses = [CodexOAuthAccountURLProtocol.self]
        let transport = CodexAuthenticatedHTTPTransport.makeClient(configuration: configuration)

        let (refreshed, depleted) = try await CodexAuthenticatedHTTPTransport.$overrideForTesting
            .withValue(transport) {
                let refreshed = try await CodexOAuthUsageFetcher.fetchUsage(
                    accessToken: "token-a",
                    accountId: "account-a",
                    env: ["CODEX_HOME": "/tmp/codexbar-oauth-request-test"])
                let depleted = try await CodexOAuthUsageFetcher.fetchUsage(
                    accessToken: "token-b",
                    accountId: "account-b",
                    env: ["CODEX_HOME": "/tmp/codexbar-oauth-request-test"])
                return (refreshed, depleted)
            }

        #expect(refreshed.rateLimit?.primaryWindow?.usedPercent == 7)
        #expect(refreshed.rateLimit?.secondaryWindow?.usedPercent == 9)
        #expect(depleted.rateLimit?.primaryWindow?.usedPercent == 100)
        #expect(depleted.rateLimit?.secondaryWindow?.usedPercent == 63)
        #expect(depleted.additionalRateLimits?.first?.rateLimit?.primaryWindow?.usedPercent == 4)

        let requests = CodexOAuthAccountURLProtocol.recordedRequests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalCacheData })
        #expect(requests.map { $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") } == ["account-a", "account-b"])
    }

    #if os(macOS)
    @MainActor
    @Test
    func `dashboard cookie requests fetch distinct cacheable responses`() async {
        defer { CodexOAuthAccountURLProtocol.reset() }
        CodexOAuthAccountURLProtocol.reset()

        let configuration = CodexAuthenticatedHTTPTransport.makeConfiguration()
        configuration.protocolClasses = [CodexOAuthAccountURLProtocol.self]
        let transport = CodexAuthenticatedHTTPTransport.makeClient(configuration: configuration)

        let (usageA, usageB) = await CodexAuthenticatedHTTPTransport.$overrideForTesting
            .withValue(transport) {
                let usageA = await OpenAIDashboardFetcher.fetchDashboardUsageAPI(
                    cookieHeader: "session=a",
                    deadline: nil,
                    logger: { _ in })
                let usageB = await OpenAIDashboardFetcher.fetchDashboardUsageAPI(
                    cookieHeader: "session=b",
                    deadline: nil,
                    logger: { _ in })
                return (usageA, usageB)
            }

        #expect(usageA?.primaryLimit?.usedPercent == 7)
        #expect(usageB?.primaryLimit?.usedPercent == 100)
        let requests = CodexOAuthAccountURLProtocol.recordedRequests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalCacheData })
        #expect(requests.map { $0.value(forHTTPHeaderField: "Cookie") } == ["session=a", "session=b"])
    }

    @MainActor
    @Test
    func `dashboard and cookie importer identity calls use isolated transport`() async throws {
        defer { CodexOAuthAccountURLProtocol.reset() }
        CodexOAuthAccountURLProtocol.reset()

        let configuration = CodexAuthenticatedHTTPTransport.makeConfiguration()
        configuration.protocolClasses = [CodexOAuthAccountURLProtocol.self]
        let transport = CodexAuthenticatedHTTPTransport.makeClient(configuration: configuration)
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "chatgpt.com",
            .path: "/",
            .name: "session",
            .value: "a",
        ]))

        let (dashboardEmail, importerEmail) = try await CodexAuthenticatedHTTPTransport.$overrideForTesting
            .withValue(transport) {
                let dashboardEmail = await OpenAIDashboardFetcher.fetchSignedInEmailFromAPI(
                    cookieHeader: "session=a",
                    deadline: nil,
                    logger: { _ in })
                let importer = OpenAIDashboardBrowserCookieImporter(browserDetection: BrowserDetection(cacheTTL: 0))
                let importerEmail = try await importer.fetchSignedInEmailFromAPI(
                    cookies: [cookie],
                    deadline: nil,
                    logger: { _ in })
                return (dashboardEmail, importerEmail)
            }

        #expect(dashboardEmail == "account-a@example.com")
        #expect(importerEmail == "account-a@example.com")
        let requests = CodexOAuthAccountURLProtocol.recordedRequests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalCacheData })
        #expect(requests.allSatisfy { $0.url?.path == "/backend-api/me" })
    }
    #endif

    @Test
    func `subscription request includes account query and maps renewal into usage`() async throws {
        let expectedRenewal = try #require(ISO8601DateFormatter().date(from: "2026-09-08T09:34:05Z"))
        let payload = Data(#"{"active_until":"2026-09-08T09:34:05Z","will_renew":true}"#.utf8)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.path == "/backend-api/subscriptions")
            #expect(components.queryItems == [URLQueryItem(name: "account_id", value: "account-a")])
            #expect(request.httpMethod == "GET")
            #expect(request.timeoutInterval == 3)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-a")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-a")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (payload, response)
        }

        let subscription = await CodexOAuthUsageFetcher.fetchSubscription(
            accessToken: "token-a",
            accountId: "account-a",
            env: ["CODEX_HOME": "/tmp/codexbar-subscription-request-test"],
            timeout: 3,
            session: transport)

        #expect(subscription?.renewsAt == expectedRenewal)
        #expect(subscription?.expiresAt == nil)
        #expect(await transport.requests().count == 1)

        let usageResponse = try CodexOAuthUsageFetcher._decodeUsageResponseForTesting(Data(#"""
        {
          "rate_limit": {
            "secondary_window": {
              "used_percent": 47,
              "reset_at": 1788272120,
              "limit_window_seconds": 604800
            }
          }
        }
        """#.utf8))
        let credentials = CodexOAuthCredentials(
            accessToken: "token-a",
            refreshToken: "refresh-a",
            idToken: nil,
            accountId: "account-a",
            lastRefresh: nil)
        let state = try #require(CodexReconciledState.fromOAuth(
            response: usageResponse,
            credentials: credentials,
            subscription: subscription,
            updatedAt: Date(timeIntervalSince1970: 1)))
        #expect(state.toUsageSnapshot().subscriptionRenewsAt == expectedRenewal)
    }

    @Test
    func `nonrenewing subscription maps its period end as expiry`() throws {
        let expectedExpiry = try #require(ISO8601DateFormatter().date(from: "2026-09-08T09:34:05Z"))
        let payload = Data(#"{"active_until":"2026-09-08T09:34:05Z","will_renew":false}"#.utf8)

        let subscription = try #require(OpenAISubscriptionDates.parse(data: payload))

        #expect(subscription.expiresAt == expectedExpiry)
        #expect(subscription.renewsAt == nil)
    }

    @Test
    func `subscription request without account id is skipped`() async {
        let transport = ProviderHTTPTransportStub { _ in
            Issue.record("Subscription transport should not run without an account ID")
            throw URLError(.badURL)
        }

        let subscription = await CodexOAuthUsageFetcher.fetchSubscription(
            accessToken: "token-a",
            accountId: "  ",
            env: ["CODEX_HOME": "/tmp/codexbar-subscription-request-test"],
            session: transport)

        #expect(subscription == nil)
        #expect(await transport.requests().isEmpty)
    }

    @Test
    func `token refresh request uses isolated cache policy`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?.absoluteString == "https://auth.openai.com/oauth/token")
            #expect(request.httpMethod == "POST")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Cache-Control": "public, max-age=300"]))
            return (Data(#"{"access_token":"new-a","refresh_token":"new-r"}"#.utf8), response)
        }
        let credentials = CodexOAuthCredentials(
            accessToken: "old-a",
            refreshToken: "old-r",
            idToken: nil,
            accountId: "account-a",
            lastRefresh: nil)

        let refreshed = try await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            try await CodexTokenRefresher.refresh(credentials)
        }

        #expect(refreshed.accessToken == "new-a")
        #expect(refreshed.refreshToken == "new-r")
        #expect(await transport.requests().count == 1)
    }
}

private final class CodexOAuthAccountURLProtocol: URLProtocol {
    private(set) nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

    static func reset() {
        self.recordedRequests = []
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.recordedRequests.append(self.request)
        guard let url = self.request.url else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let accountKey = self.request.value(forHTTPHeaderField: "ChatGPT-Account-Id")
            ?? self.request.value(forHTTPHeaderField: "Cookie")
        if self.request.url?.path == "/backend-api/me" {
            let email = accountKey == "session=a" ? "account-a@example.com" : "account-b@example.com"
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Cache-Control": "public, max-age=300"])
            else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            self.client?.urlProtocol(self, didLoad: Data(#"{"email":"\#(email)"}"#.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
            return
        }
        let payload: String? = switch accountKey {
        case "account-a", "session=a": Self.payload(primary: 7, secondary: 9, spark: 2)
        case "account-b", "session=b": Self.payload(primary: 100, secondary: 63, spark: 4)
        default: nil
        }
        guard let payload,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: ["Cache-Control": "public, max-age=300"])
        else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }

        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        self.client?.urlProtocol(self, didLoad: Data(payload.utf8))
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func payload(primary: Int, secondary: Int, spark: Int) -> String {
        """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": \(primary), "reset_at": 1766948068, "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": \(secondary), "reset_at": 1767407914, "limit_window_seconds": 604800
            }
          },
          "additional_rate_limits": [{
            "limit_name": "GPT-5.3-Codex-Spark",
            "rate_limit": {
              "primary_window": {
                "used_percent": \(spark), "reset_at": 1766948068, "limit_window_seconds": 18000
              }
            }
          }]
        }
        """
    }
}
