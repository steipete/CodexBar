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
            let usageCookies = RequestHeaderLog()

            try await self.withClaudeWebStub { request in
                if request.url?.path == "/api/organizations/org-123/usage" {
                    usageCookies.append(request.value(forHTTPHeaderField: "Cookie"))
                }
                return try Self.response(for: request, setCookie: Self.renewedSessionCookie)
            } operation: {
                let usage = try await ClaudeWebAPIFetcher.fetchUsage(cookieHeader: "sessionKey=sk-ant-manual-token")

                #expect(usage.sessionPercentUsed == 11)
                #expect(usageCookies.values == ["sessionKey=sk-ant-renewed-token"])
                let cached = try #require(CookieHeaderCache.load(provider: .claude))
                #expect(cached.cookieHeader == "sessionKey=sk-ant-cache-token")
                #expect(cached.sourceLabel == "Chrome")
            }
        }
    }

    @Test
    func `usage response renewal propagates to later requests and cache`() async throws {
        try await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-old-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }
            let usageCookies = RequestHeaderLog()
            let overageCookies = RequestHeaderLog()
            let accountCookies = RequestHeaderLog()

            try await self.withClaudeWebStub { request in
                let path = request.url?.path
                switch path {
                case "/api/organizations/org-123/usage":
                    usageCookies.append(request.value(forHTTPHeaderField: "Cookie"))
                case "/api/organizations/org-123/overage_spend_limit":
                    overageCookies.append(request.value(forHTTPHeaderField: "Cookie"))
                case "/api/account":
                    accountCookies.append(request.value(forHTTPHeaderField: "Cookie"))
                default:
                    break
                }
                return try Self.response(
                    for: request,
                    setCookie: path == "/api/organizations/org-123/usage" ? Self.renewedSessionCookie : nil)
            } operation: {
                _ = try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: BrowserDetection(cacheTTL: 0))

                #expect(usageCookies.values == ["sessionKey=sk-ant-old-token"])
                #expect(overageCookies.values == ["sessionKey=sk-ant-renewed-token"])
                #expect(accountCookies.values == ["sessionKey=sk-ant-renewed-token"])
                let cached = try #require(CookieHeaderCache.load(provider: .claude))
                #expect(cached.cookieHeader == "sessionKey=sk-ant-renewed-token")
            }
        }
    }

    @Test
    func `renewal can return to initial session key`() async throws {
        try await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-initial-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }
            let usageCookies = RequestHeaderLog()
            let overageCookies = RequestHeaderLog()
            let accountCookies = RequestHeaderLog()

            try await self.withClaudeWebStub { request in
                let path = request.url?.path
                switch path {
                case "/api/organizations/org-123/usage":
                    usageCookies.append(request.value(forHTTPHeaderField: "Cookie"))
                case "/api/organizations/org-123/overage_spend_limit":
                    overageCookies.append(request.value(forHTTPHeaderField: "Cookie"))
                case "/api/account":
                    accountCookies.append(request.value(forHTTPHeaderField: "Cookie"))
                default:
                    break
                }
                let setCookie: String? = switch path {
                case "/api/organizations":
                    "sessionKey=sk-ant-intermediate-token; Path=/; HttpOnly"
                case "/api/organizations/org-123/usage":
                    "sessionKey=sk-ant-initial-token; Path=/; HttpOnly"
                default:
                    nil
                }
                return try Self.response(for: request, setCookie: setCookie)
            } operation: {
                _ = try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: BrowserDetection(cacheTTL: 0))

                #expect(usageCookies.values == ["sessionKey=sk-ant-intermediate-token"])
                #expect(overageCookies.values == ["sessionKey=sk-ant-initial-token"])
                #expect(accountCookies.values == ["sessionKey=sk-ant-initial-token"])
                let cached = try #require(CookieHeaderCache.load(provider: .claude))
                #expect(cached.cookieHeader == "sessionKey=sk-ant-initial-token")
                #expect(cached.sourceLabel == "Chrome")
            }
        }
    }

    @Test
    func `last session key assignment in one response wins`() async throws {
        try await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-old-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }
            let usageCookies = RequestHeaderLog()
            let overageCookies = RequestHeaderLog()
            let accountCookies = RequestHeaderLog()

            try await self.withClaudeWebStub { request in
                let path = request.url?.path
                switch path {
                case "/api/organizations/org-123/usage":
                    usageCookies.append(request.value(forHTTPHeaderField: "Cookie"))
                case "/api/organizations/org-123/overage_spend_limit":
                    overageCookies.append(request.value(forHTTPHeaderField: "Cookie"))
                case "/api/account":
                    accountCookies.append(request.value(forHTTPHeaderField: "Cookie"))
                default:
                    break
                }
                let setCookie = path == "/api/organizations"
                    ? "sessionKey=sk-ant-first-token; Expires=Wed, 21 Oct 2030 07:28:00 GMT; Path=/, "
                    + "sessionKey=sk-ant-final-token; Path=/; HttpOnly"
                    : nil
                return try Self.response(for: request, setCookie: setCookie)
            } operation: {
                _ = try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: BrowserDetection(cacheTTL: 0))

                #expect(usageCookies.values == ["sessionKey=sk-ant-final-token"])
                #expect(overageCookies.values == ["sessionKey=sk-ant-final-token"])
                #expect(accountCookies.values == ["sessionKey=sk-ant-final-token"])
                let cached = try #require(CookieHeaderCache.load(provider: .claude))
                #expect(cached.cookieHeader == "sessionKey=sk-ant-final-token")
                #expect(cached.sourceLabel == "Chrome")
            }
        }
    }

    private static let renewedSessionCookie =
        "sessionKey=sk-ant-renewed-token; Path=/; HttpOnly; Secure; SameSite=Lax"

    private func withIsolatedCookieCache<T>(_ operation: () async throws -> T) async rethrows -> T {
        let legacyBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-web-renewal-\(UUID().uuidString)", isDirectory: true)
        return try await KeychainCacheStore.withServiceOverrideForTesting("claude-web-renewal-\(UUID().uuidString)") {
            try await CookieHeaderCache.withLegacyBaseURLOverrideForTesting(legacyBase) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }
                CookieHeaderCache.resetDisplayCacheForTesting()
                defer { CookieHeaderCache.resetDisplayCacheForTesting() }
                return try await operation()
            }
        }
    }

    private func withClaudeWebStub<T>(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data),
        operation: () async throws -> T) async rethrows -> T
    {
        let transport = ProviderHTTPTransportHandler { request in
            let (response, data) = try handler(request)
            return (data, response)
        }
        return try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
            try await operation()
        }
    }

    private static func response(
        for request: URLRequest,
        setCookie: String?) throws -> (HTTPURLResponse, Data)
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
        setCookie: String?) -> (HTTPURLResponse, Data)
    {
        var headerFields = ["Content-Type": "application/json"]
        if let setCookie {
            headerFields["Set-Cookie"] = setCookie
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields)!
        return (response, Data(body.utf8))
    }
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
