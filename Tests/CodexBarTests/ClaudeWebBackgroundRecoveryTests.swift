import Foundation
import Testing
@testable import CodexBarCore

/// Covers the same background-refresh recovery shape as `OllamaUsageFetcherRetryMappingTests`, applied to
/// `ClaudeWebAPIFetcher.fetchUsageSerialized`: a background refresh must still attempt browser-cookie recovery
/// after a stale cached cookie is invalidated (the gate itself decides whether that read needs an interactive
/// prompt), but must surface the original, more informative cached-auth error — not a generic "no session key
/// found" — when that recovery attempt comes back empty.
@Suite(.serialized)
struct ClaudeWebBackgroundRecoveryTests {
    private static let challengeMessage =
        "claude.ai is behind a Cloudflare challenge, often caused by VPN or datacenter networks. " +
        "Re-authenticating will not help. Switch Claude Usage source to OAuth in Settings " +
        "(Usage credits balance will be unavailable), or try a different network."

    @Test
    func `Cloudflare challenge preserves cached cookie without browser recovery`() async {
        await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-current-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }
            let replacement = ClaudeWebAPIFetcher.SessionKeyInfo(
                key: "sk-ant-should-not-import",
                sourceLabel: "Safari",
                cookieCount: 1)

            do {
                _ = try await ClaudeWebSessionKeyImport.$overrideForTesting.withValue(replacement) {
                    try await self.withClaudeWebStub { request in
                        let url = try #require(request.url)
                        if url.path == "/api/organizations" {
                            let response = try #require(HTTPURLResponse(
                                url: url,
                                statusCode: 403,
                                httpVersion: "HTTP/1.1",
                                headerFields: ["cf-mitigated": "challenge"]))
                            return (response, Data("challenge".utf8))
                        }
                        return try Self.response(for: request, setCookie: nil)
                    } operation: {
                        try await ClaudeWebAPIFetcher.fetchUsage(
                            browserDetection: BrowserDetection(cacheTTL: 0))
                    }
                }
                Issue.record("Expected Cloudflare challenge")
            } catch {
                #expect(error.localizedDescription == Self.challengeMessage)
            }

            let cached = try? #require(CookieHeaderCache.load(provider: .claude))
            #expect(cached?.cookieHeader == "sessionKey=sk-ant-current-token")
            #expect(cached?.sourceLabel == "Chrome")
        }
    }

    @Test
    func `background refresh surfaces original auth error when browser recovery finds nothing`() async {
        await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-stale-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }

            await #expect(throws: ClaudeWebAPIFetcher.FetchError.self) {
                try await ProviderInteractionContext.$current.withValue(.background) {
                    try await self.withClaudeWebStub { request in
                        let isStale = request.value(forHTTPHeaderField: "Cookie") ==
                            "sessionKey=sk-ant-stale-token"
                        if request.url?.path == "/api/organizations", isStale {
                            let url = try #require(request.url)
                            return Self.jsonResponse(url: url, body: "{}", statusCode: 401, setCookie: nil)
                        }
                        return try Self.response(for: request, setCookie: nil)
                    } operation: {
                        // No `ClaudeWebSessionKeyImport.overrideForTesting` is installed, so browser recovery
                        // finds no candidates — mirroring a real background attempt where no browser yields a
                        // session key.
                        _ = try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: BrowserDetection(cacheTTL: 0))
                    }
                }
            }

            // The stale cache was cleared by the invalidation attempt (matches the Ollama behavior); only the
            // *error surfaced to the caller* is what this test guards.
            #expect(CookieHeaderCache.load(provider: .claude) == nil)
        }
    }

    @Test
    func `background refresh still recovers when browser cookie read succeeds without a prompt`() async throws {
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

            try await ProviderInteractionContext.$current.withValue(.background) {
                try await ClaudeWebSessionKeyImport.$overrideForTesting.withValue(imported) {
                    try await self.withClaudeWebStub { request in
                        let isStale = request.value(forHTTPHeaderField: "Cookie") ==
                            "sessionKey=sk-ant-stale-token"
                        if request.url?.path == "/api/organizations", isStale {
                            let url = try #require(request.url)
                            return Self.jsonResponse(url: url, body: "{}", statusCode: 401, setCookie: nil)
                        }
                        return try Self.response(for: request, setCookie: nil)
                    } operation: {
                        let usage = try await ClaudeWebAPIFetcher.fetchUsage(
                            browserDetection: BrowserDetection(cacheTTL: 0))
                        #expect(usage.sessionPercentUsed == 11)
                    }
                }
            }

            let cached = try #require(CookieHeaderCache.load(provider: .claude))
            #expect(cached.cookieHeader == "sessionKey=sk-ant-imported-token")
            #expect(cached.sourceLabel == "Safari")
        }
    }

    @Test
    func `user initiated refresh surfaces original auth error when browser recovery finds nothing`() async {
        await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-stale-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }

            await #expect(throws: ClaudeWebAPIFetcher.FetchError.self) {
                try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try await self.withClaudeWebStub { request in
                        let isStale = request.value(forHTTPHeaderField: "Cookie") ==
                            "sessionKey=sk-ant-stale-token"
                        if request.url?.path == "/api/organizations", isStale {
                            let url = try #require(request.url)
                            return Self.jsonResponse(url: url, body: "{}", statusCode: 401, setCookie: nil)
                        }
                        return try Self.response(for: request, setCookie: nil)
                    } operation: {
                        _ = try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: BrowserDetection(cacheTTL: 0))
                    }
                }
            }
        }
    }

    // MARK: - Helpers (mirrors ClaudeWebCookieRenewalTests' stub/cache isolation)

    private func withIsolatedCookieCache<T>(_ operation: () async throws -> T) async rethrows -> T {
        let legacyBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-web-background-recovery-\(UUID().uuidString)", isDirectory: true)
        return try await KeychainCacheStore.withServiceOverrideForTesting(
            "claude-web-background-recovery-\(UUID().uuidString)")
        {
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
