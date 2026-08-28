import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeWebCookieRenewalTests {
    @Test
    func `stalled prepaid credits request does not fail completed usage`() async throws {
        let probe = ClaudePrepaidRequestProbe()
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            if url.path == "/api/organizations/org-123/prepaid/credits" {
                try await probe.stallUntilCancelled()
            }
            let (response, data) = try Self.response(for: request, setCookie: nil)
            return (data, response)
        }
        let usage = try await ClaudeWebPrepaidCreditsRequest.$timeoutOverrideForTesting.withValue(
            .milliseconds(20))
        {
            try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
                try await ClaudeWebAPIFetcher.fetchUsage(
                    cookieHeader: "sessionKey=sk-ant-manual-token")
            }
        }

        #expect(usage.sessionPercentUsed == 11)
        #expect(usage.extraUsageCost?.balance == nil)
        #expect(await probe.waitForCancellation())
    }

    @Test
    func `caller cancellation during prepaid credits request is propagated`() async {
        let probe = ClaudePrepaidRequestProbe()
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            if url.path == "/api/organizations/org-123/prepaid/credits" {
                try await probe.stallUntilCancelled()
            }
            let (response, data) = try Self.response(for: request, setCookie: nil)
            return (data, response)
        }
        let fetchTask = Task {
            try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
                try await ClaudeWebAPIFetcher.fetchUsage(
                    cookieHeader: "sessionKey=sk-ant-manual-token")
            }
        }

        await probe.waitUntilStarted()
        fetchTask.cancel()

        await #expect(throws: CancellationError.self) {
            try await fetchTask.value
        }
        #expect(await probe.waitForCancellation())
    }

    @Test
    func `web fetch merges prepaid credits into Claude extra usage cost`() async throws {
        try await self.withClaudeWebStub { request in
            let url = try #require(request.url)
            if url.path == "/api/organizations/org-123/prepaid/credits" {
                return Self.jsonResponse(
                    url: url,
                    body: #"{"amount":10000,"currency":"USD"}"#,
                    setCookie: nil)
            }
            if url.path == "/api/organizations/org-123/usage" {
                return Self.jsonResponse(
                    url: url,
                    body: """
                    {
                      "five_hour": { "utilization": 11 },
                      "extra_usage": {
                        "is_enabled": true,
                        "monthly_limit": 2000,
                        "used_credits": 500,
                        "currency": "USD"
                      }
                    }
                    """,
                    setCookie: nil)
            }
            return try Self.response(for: request, setCookie: nil)
        } operation: {
            let usage = try await ClaudeWebAPIFetcher.fetchUsage(
                cookieHeader: "sessionKey=sk-ant-manual-token")

            #expect(usage.extraUsageCost?.balance == 100)
            #expect(usage.extraUsageCost?.currencyCode == "USD")
        }
    }

    @Test
    func `balance only fetch skips legacy overage request`() async throws {
        let paths = RequestHeaderLog()
        try await self.withClaudeWebStub { request in
            let url = try #require(request.url)
            paths.append(url.path)
            if url.path == "/api/organizations/org-123/prepaid/credits" {
                return Self.jsonResponse(
                    url: url,
                    body: #"{"amount":10000,"currency":"USD"}"#,
                    setCookie: nil)
            }
            return try Self.response(for: request, setCookie: nil)
        } operation: {
            let usage = try await ClaudeWebAPIFetcher.fetchUsage(
                cookieHeader: "sessionKey=sk-ant-manual-token",
                includeUsageDetails: false,
                includePrepaidBalance: true)

            #expect(usage.extraUsageCost?.balance == 100)
            #expect(usage.extraUsageCost?.used == 0)
            #expect(usage.extraUsageCost?.limit == 0)
            #expect(!paths.values.contains("/api/organizations/org-123/overage_spend_limit"))
        }
    }

    @Test
    func `balance enrichment preserves extra usage cost from usage response`() async throws {
        let paths = RequestHeaderLog()
        try await self.withClaudeWebStub { request in
            let url = try #require(request.url)
            paths.append(url.path)
            switch url.path {
            case "/api/organizations/org-123/usage":
                return Self.jsonResponse(
                    url: url,
                    body: """
                    {
                      "five_hour": { "utilization": 11 },
                      "extra_usage": {
                        "is_enabled": true,
                        "monthly_limit": 10000,
                        "used_credits": 42,
                        "currency": "USD"
                      }
                    }
                    """,
                    setCookie: nil)
            case "/api/organizations/org-123/prepaid/credits":
                return Self.jsonResponse(
                    url: url,
                    body: #"{"amount":9958,"currency":"USD"}"#,
                    setCookie: nil)
            default:
                return try Self.response(for: request, setCookie: nil)
            }
        } operation: {
            let usage = try await ClaudeWebAPIFetcher.fetchUsage(
                cookieHeader: "sessionKey=sk-ant-manual-token",
                includeUsageDetails: false,
                includePrepaidBalance: true)

            #expect(usage.extraUsageCost?.used == 0.42)
            #expect(usage.extraUsageCost?.limit == 100)
            #expect(usage.extraUsageCost?.balance == 99.58)
            #expect(!paths.values.contains("/api/organizations/org-123/overage_spend_limit"))
        }
    }

    @Test
    func `web fetch skips prepaid credits when optional usage is disabled`() async throws {
        let paths = RequestHeaderLog()
        try await self.withClaudeWebStub { request in
            paths.append(request.url?.path)
            return try Self.response(for: request, setCookie: nil)
        } operation: {
            let usage = try await ClaudeWebAPIFetcher.fetchUsage(
                cookieHeader: "sessionKey=sk-ant-manual-token",
                includePrepaidBalance: false)

            #expect(usage.sessionPercentUsed == 11)
            #expect(!paths.values.contains("/api/organizations/org-123/prepaid/credits"))
        }
    }

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
    func `cached fetch without renewal does not block concurrent renewal`() async throws {
        try await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-old-token",
                sourceLabel: "Chrome",
                now: Date(timeIntervalSince1970: 1))
            defer { CookieHeaderCache.clear(provider: .claude) }
            let initial = try #require(CookieHeaderCache.load(provider: .claude))

            try await self.withClaudeWebStub { request in
                try Self.response(for: request, setCookie: nil)
            } operation: {
                _ = try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: BrowserDetection(cacheTTL: 0))
            }

            let renewed = CookieHeaderCache.storeIfCurrent(
                provider: .claude,
                expected: initial,
                cookieHeader: "sessionKey=sk-ant-concurrent-renewal",
                sourceLabel: "Chrome")
            #expect(renewed)
            #expect(CookieHeaderCache.load(provider: .claude)?.cookieHeader ==
                "sessionKey=sk-ant-concurrent-renewal")
        }
    }

    @Test
    func `browser fallback replaces stale cache when conditional clear fails`() async throws {
        try await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-stale-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }
            let imported = ClaudeWebAPIFetcher.SessionKeyInfo(
                key: "sk-ant-imported-token",
                sourceLabel: "Safari",
                cookieCount: 1)

            try await KeychainCacheStore.withClearFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
                try await ClaudeWebSessionKeyImport.$overrideForTesting.withValue(imported) {
                    try await self.withClaudeWebStub { request in
                        let isStale = request.value(forHTTPHeaderField: "Cookie") ==
                            "sessionKey=sk-ant-stale-token"
                        if request.url?.path == "/api/organizations", isStale {
                            let url = try #require(request.url)
                            return Self.jsonResponse(
                                url: url,
                                body: "{}",
                                statusCode: 401,
                                setCookie: nil)
                        }
                        return try Self.response(for: request, setCookie: nil)
                    } operation: {
                        _ = try await ClaudeWebAPIFetcher.fetchUsage(
                            browserDetection: BrowserDetection(cacheTTL: 0))
                    }
                }
            }

            let cached = try #require(CookieHeaderCache.load(provider: .claude))
            #expect(cached.cookieHeader == "sessionKey=sk-ant-imported-token")
            #expect(cached.sourceLabel == "Safari")
        }
    }

    @Test
    func `concurrent cached fetches serialize session key rotations`() async throws {
        try await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-initial-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }
            let probe = ConcurrentClaudeFetchProbe()
            let transport = ProviderHTTPTransportHandler { request in
                let setCookie: String? = if request.url?.path == "/api/organizations" {
                    await probe.organizationSessionCookie(
                        requestCookie: request.value(forHTTPHeaderField: "Cookie"))
                } else {
                    nil
                }
                let (response, data) = try Self.response(for: request, setCookie: setCookie)
                return (data, response)
            }

            try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
                let first = Task {
                    try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: BrowserDetection(cacheTTL: 0))
                }
                await probe.waitForOrganizationCount(1)
                let second = Task {
                    try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: BrowserDetection(cacheTTL: 0))
                }
                for _ in 0..<20 {
                    await Task.yield()
                }
                #expect(await probe.organizationRequestCount == 1)

                await probe.releaseFirstRequest()
                _ = try await first.value
                _ = try await second.value
            }

            #expect(await probe.organizationRequestCookies == [
                "sessionKey=sk-ant-initial-token",
                "sessionKey=sk-ant-first-rotation",
            ])
            #expect(CookieHeaderCache.load(provider: .claude)?.cookieHeader ==
                "sessionKey=sk-ant-second-rotation")
        }
    }

    @Test
    func `cancelled waiting fetch relinquishes the serialization gate`() async throws {
        try await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-initial-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }
            let probe = ConcurrentClaudeFetchProbe()
            let transport = ProviderHTTPTransportHandler { request in
                let setCookie: String? = if request.url?.path == "/api/organizations" {
                    await probe.organizationSessionCookie(
                        requestCookie: request.value(forHTTPHeaderField: "Cookie"))
                } else {
                    nil
                }
                let (response, data) = try Self.response(for: request, setCookie: setCookie)
                return (data, response)
            }

            try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
                let first = Task {
                    try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: BrowserDetection(cacheTTL: 0))
                }
                await probe.waitForOrganizationCount(1)
                let cancelled = Task {
                    try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: BrowserDetection(cacheTTL: 0))
                }
                for _ in 0..<20 {
                    await Task.yield()
                }
                cancelled.cancel()
                await #expect(throws: CancellationError.self) {
                    try await cancelled.value
                }
                #expect(await probe.organizationRequestCount == 1)

                await probe.releaseFirstRequest()
                _ = try await first.value
                _ = try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: BrowserDetection(cacheTTL: 0))
            }

            #expect(await probe.organizationRequestCookies == [
                "sessionKey=sk-ant-initial-token",
                "sessionKey=sk-ant-first-rotation",
            ])
            #expect(CookieHeaderCache.load(provider: .claude)?.cookieHeader ==
                "sessionKey=sk-ant-second-rotation")
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
    func `usage and prepaid response renewals propagate to later requests and cache`() async throws {
        try await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-old-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }
            let usageCookies = RequestHeaderLog()
            let overageCookies = RequestHeaderLog()
            let prepaidCookies = RequestHeaderLog()
            let accountCookies = RequestHeaderLog()

            try await self.withClaudeWebStub { request in
                let path = request.url?.path
                switch path {
                case "/api/organizations/org-123/usage":
                    usageCookies.append(request.value(forHTTPHeaderField: "Cookie"))
                case "/api/organizations/org-123/overage_spend_limit":
                    overageCookies.append(request.value(forHTTPHeaderField: "Cookie"))
                case "/api/organizations/org-123/prepaid/credits":
                    prepaidCookies.append(request.value(forHTTPHeaderField: "Cookie"))
                case "/api/account":
                    accountCookies.append(request.value(forHTTPHeaderField: "Cookie"))
                default:
                    break
                }
                let setCookie: String? = switch path {
                case "/api/organizations/org-123/usage":
                    Self.renewedSessionCookie
                case "/api/organizations/org-123/prepaid/credits":
                    "sessionKey=sk-ant-prepaid-token; Path=/; HttpOnly"
                default:
                    nil
                }
                if path == "/api/organizations/org-123/prepaid/credits" {
                    return try Self.jsonResponse(
                        url: #require(request.url),
                        body: #"{"amount":10000,"currency":"USD"}"#,
                        setCookie: setCookie)
                }
                return try Self.response(
                    for: request,
                    setCookie: setCookie)
            } operation: {
                _ = try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: BrowserDetection(cacheTTL: 0))

                #expect(usageCookies.values == ["sessionKey=sk-ant-old-token"])
                #expect(overageCookies.values == ["sessionKey=sk-ant-renewed-token"])
                #expect(prepaidCookies.values == ["sessionKey=sk-ant-renewed-token"])
                #expect(accountCookies.values == ["sessionKey=sk-ant-prepaid-token"])
                let cached = try #require(CookieHeaderCache.load(provider: .claude))
                #expect(cached.cookieHeader == "sessionKey=sk-ant-prepaid-token")
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

private actor ClaudePrepaidRequestProbe {
    private var started = false
    private var cancelled = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func stallUntilCancelled() async throws {
        self.started = true
        for waiter in self.startedWaiters {
            waiter.resume()
        }
        self.startedWaiters.removeAll()

        do {
            try await Task.sleep(for: .seconds(10))
        } catch {
            self.cancelled = true
            throw error
        }
        throw CancellationError()
    }

    func waitUntilStarted() async {
        if self.started { return }
        await withCheckedContinuation { continuation in
            self.startedWaiters.append(continuation)
        }
    }

    func waitForCancellation() async -> Bool {
        for _ in 0..<100 {
            if self.cancelled { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return self.cancelled
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

private actor ConcurrentClaudeFetchProbe {
    private var requestCookies: [String?] = []
    private var organizationCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var firstRequestReleased = false
    private var firstRequestReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    var organizationRequestCount: Int {
        self.requestCookies.count
    }

    var organizationRequestCookies: [String?] {
        self.requestCookies
    }

    func organizationSessionCookie(requestCookie: String?) async -> String {
        self.requestCookies.append(requestCookie)
        let ordinal = self.requestCookies.count
        let readyWaiters = self.organizationCountWaiters.filter { $0.0 <= ordinal }
        self.organizationCountWaiters.removeAll { $0.0 <= ordinal }
        readyWaiters.forEach { $0.1.resume() }
        if ordinal == 1, !self.firstRequestReleased {
            await withCheckedContinuation { continuation in
                self.firstRequestReleaseWaiters.append(continuation)
            }
        }
        let value = ordinal == 1 ? "sk-ant-first-rotation" : "sk-ant-second-rotation"
        return "sessionKey=\(value); Path=/; HttpOnly"
    }

    func waitForOrganizationCount(_ count: Int) async {
        if self.requestCookies.count >= count { return }
        await withCheckedContinuation { continuation in
            self.organizationCountWaiters.append((count, continuation))
        }
    }

    func releaseFirstRequest() {
        self.firstRequestReleased = true
        let waiters = self.firstRequestReleaseWaiters
        self.firstRequestReleaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
