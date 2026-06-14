import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeWebCookieRenewalTests {
    @Test
    func `cached web session key renews from set cookie after successful fetch`() async throws {
        try await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-old-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }
            let usageCookies = RequestHeaderLog()

            try await self.withClaudeWebStub { request in
                if request.url?.path == "/api/organizations/org-123/usage" {
                    usageCookies.append(request.value(forHTTPHeaderField: "Cookie"))
                }
                return try Self.response(for: request, setCookie: Self.renewedSessionCookie)
            } operation: {
                let usage = try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: BrowserDetection(cacheTTL: 0))

                #expect(usage.sessionPercentUsed == 11)
                #expect(usage.weeklyPercentUsed == 22)
                #expect(usageCookies.values == ["sessionKey=sk-ant-renewed-token"])
                let cached = try #require(CookieHeaderCache.load(provider: .claude))
                #expect(cached.cookieHeader == "sessionKey=sk-ant-renewed-token")
                #expect(cached.sourceLabel == "Chrome")
            }
        }
    }

    @Test
    func `manual web session fetch does not rewrite cached cookie`() async throws {
        try await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-cache-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }

            try await self.withClaudeWebStub { request in
                try Self.response(for: request, setCookie: Self.renewedSessionCookie)
            } operation: {
                let usage = try await ClaudeWebAPIFetcher.fetchUsage(cookieHeader: "sessionKey=sk-ant-manual-token")

                #expect(usage.sessionPercentUsed == 11)
                let cached = try #require(CookieHeaderCache.load(provider: .claude))
                #expect(cached.cookieHeader == "sessionKey=sk-ant-cache-token")
                #expect(cached.sourceLabel == "Chrome")
            }
        }
    }

    private static let renewedSessionCookie =
        "sessionKey=sk-ant-renewed-token; Path=/; HttpOnly; Secure; SameSite=Lax"

    private func withIsolatedCookieCache<T>(_ operation: () async throws -> T) async rethrows -> T {
        try await KeychainCacheStore.withServiceOverrideForTesting("claude-web-renewal-\(UUID().uuidString)") {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            CookieHeaderCache.resetDisplayCacheForTesting()
            defer { CookieHeaderCache.resetDisplayCacheForTesting() }
            return try await operation()
        }
    }

    private func withClaudeWebStub<T>(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data),
        operation: () async throws -> T) async rethrows -> T
    {
        let registered = URLProtocol.registerClass(ClaudeWebCookieRenewalStubURLProtocol.self)
        ClaudeWebCookieRenewalStubURLProtocol.handler = handler
        defer {
            if registered {
                URLProtocol.unregisterClass(ClaudeWebCookieRenewalStubURLProtocol.self)
            }
            ClaudeWebCookieRenewalStubURLProtocol.handler = nil
        }
        return try await operation()
    }

    private static func response(
        for request: URLRequest,
        setCookie: String) throws -> (HTTPURLResponse, Data)
    {
        let url = try #require(request.url)
        switch url.path {
        case "/api/organizations":
            return self.jsonResponse(
                url: url,
                body: #"[{"uuid":"org-123","name":"Test Org","capabilities":["chat"]}]"#,
                setCookie: setCookie)
        case "/api/organizations/org-123/usage":
            return self.jsonResponse(
                url: url,
                body: """
                {
                  "five_hour": { "utilization": 11 },
                  "seven_day": { "utilization": 22 }
                }
                """,
                setCookie: setCookie)
        case "/api/account", "/api/organizations/org-123/overage_spend_limit":
            return self.jsonResponse(url: url, body: "{}", statusCode: 404, setCookie: setCookie)
        default:
            return self.jsonResponse(url: url, body: "{}", statusCode: 404, setCookie: setCookie)
        }
    }

    private static func jsonResponse(
        url: URL,
        body: String,
        statusCode: Int = 200,
        setCookie: String) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "Set-Cookie": setCookie,
            ])!
        return (response, Data(body.utf8))
    }
}

private final class ClaudeWebCookieRenewalStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "claude.ai"
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

private final class RequestHeaderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []

    var values: [String?] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }

    func append(_ value: String?) {
        self.lock.lock()
        self.storage.append(value)
        self.lock.unlock()
    }
}
