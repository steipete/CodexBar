import Foundation
import Testing
@testable import CodexBarCore

/// Covers the `.auto` cookie-cache handoff: a validated browser session is persisted through
/// `CookieHeaderCache`, and later resolutions (background refreshes, the bundled CLI) run from the
/// cached header without rereading the browser. Modeled on `PerplexityCookieCacheTests`.
@Suite(.serialized)
struct ZoomMateCookieCacheTests {
    private static let cachedHeader = "_zm_ssid=fake-session-value; cf_clearance=fake-clearance-value"

    /// Minimal unsigned JWT carrying only a far-future `exp` claim, so minted tokens are cacheable.
    private static func makeJWT(exp: Int = 9_999_999_999) -> String {
        func b64url(_ text: String) -> String {
            Data(text.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64url("{\"alg\":\"none\"}")).\(b64url("{\"exp\":\(exp)}")).sig"
    }

    private static func mintResponseStub(
        nak: String,
        email: String? = nil,
        expectedCookieHeader: String? = nil) -> ProviderHTTPTransportStub
    {
        ProviderHTTPTransportStub { request in
            if let expectedCookieHeader {
                #expect(request.value(forHTTPHeaderField: "Cookie") == expectedCookieHeader)
            }
            let profile = email.map { ", \"user_profile\": {\"email\": \"\($0)\"}" } ?? ""
            let body = "{\"success\": true, \"data\": {\"nak\": \"\(nak)\"\(profile)}}"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    #if os(macOS)
    @Test
    func `auto mode reuses the cached cookie header without a browser read`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .zoommate)
            KeychainCacheStore.setTestStoreForTesting(false)
        }
        CookieHeaderCache.store(
            provider: .zoommate,
            cookieHeader: Self.cachedHeader,
            sourceLabel: "Chrome (Test)")

        let jwt = Self.makeJWT()
        let stub = Self.mintResponseStub(
            nak: jwt,
            email: "fake.user@example.com",
            expectedCookieHeader: Self.cachedHeader)
        let fetcher = ZoomMateUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0))

        let context = try await fetcher.resolveRequestContext(
            manualCaptureOverride: nil,
            timeout: 1,
            logger: nil,
            cache: ZoomMateBearerTokenCache(),
            transport: stub)

        #expect(context.authorization == "Bearer \(jwt)")
        #expect(context.headers["Cookie"] == Self.cachedHeader)
        #expect(context.accountEmail == "fake.user@example.com")
        #expect(context.cacheKey == ZoomMateBearerTokenCache.key(forCookieHeader: Self.cachedHeader))
        #expect(await stub.requests().count == 1) // the mint only — no browser import happened
    }

    @Test
    func `resolution without cache falls back to the browser import path`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .zoommate)
            KeychainCacheStore.setTestStoreForTesting(false)
        }
        CookieHeaderCache.store(
            provider: .zoommate,
            cookieHeader: Self.cachedHeader,
            sourceLabel: "Chrome (Test)")

        let stub = ProviderHTTPTransportStub { request in
            Issue.record("Unexpected network request: \(request.url?.absoluteString ?? "nil")")
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        let fetcher = ZoomMateUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0))

        // The dead-session retry disallows the cache; under the test runner the browser cookie
        // store is suppressed, so the fallback surfaces `noSession` without any network traffic.
        await #expect {
            _ = try await fetcher.resolveRequestContext(
                manualCaptureOverride: nil,
                allowCachedCookieHeader: false,
                timeout: 1,
                logger: nil,
                cache: ZoomMateBearerTokenCache(),
                transport: stub)
        } throws: { error in
            guard case ZoomMateUsageError.noSession = error else { return false }
            return true
        }
        // Skipping the cache must not mutate it; clearing is the strategy's explicit decision.
        #expect(CookieHeaderCache.load(provider: .zoommate)?.cookieHeader == Self.cachedHeader)
    }

    @Test
    func `rejected cached session surfaces invalidCredentials and leaves the entry intact`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .zoommate)
            KeychainCacheStore.setTestStoreForTesting(false)
        }
        CookieHeaderCache.store(
            provider: .zoommate,
            cookieHeader: Self.cachedHeader,
            sourceLabel: "Chrome (Test)")

        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), response)
        }
        let fetcher = ZoomMateUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0))

        await #expect {
            _ = try await fetcher.resolveRequestContext(
                manualCaptureOverride: nil,
                timeout: 1,
                logger: nil,
                cache: ZoomMateBearerTokenCache(),
                transport: stub)
        } throws: { error in
            guard case ZoomMateUsageError.invalidCredentials = error else { return false }
            return true
        }
        // The fetcher never clears the cache itself — the strategy clears and retries once with a
        // fresh import, so a transient mis-clear can't wipe a concurrently refreshed entry.
        #expect(CookieHeaderCache.load(provider: .zoommate) != nil)
    }

    @Test
    func `validated browser session is persisted through the cookie cache`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .zoommate)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        let nak = Self.makeJWT()
        let stub = Self.mintResponseStub(nak: nak, expectedCookieHeader: Self.cachedHeader)

        let context = try await ZoomMateUsageFetcher.requestContext(
            forCookieHeader: Self.cachedHeader,
            persistingValidatedHeaderAs: "Chrome (Test)",
            cache: ZoomMateBearerTokenCache(),
            timeout: 1,
            transport: stub,
            logger: nil)

        let cached = try #require(CookieHeaderCache.load(provider: .zoommate))
        #expect(cached.cookieHeader == Self.cachedHeader)
        #expect(cached.sourceLabel == "Chrome (Test)")
        // Only the cookie header is persisted — the minted bearer stays in memory.
        #expect(!cached.cookieHeader.contains(nak))
        #expect(context.authorization == "Bearer \(nak)")
    }

    @Test
    func `auto mode continues past a rejected Chrome profile`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .zoommate)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        let rejectedHeader = "_zm_ssid=fake-rejected-session"
        let validHeader = "_zm_ssid=fake-valid-session"
        let jwt = Self.makeJWT()
        let sessions = [
            ZoomMateCookieImporter.SessionInfo(
                cookieHeader: rejectedHeader,
                sourceLabel: "Chrome Profile 1"),
            ZoomMateCookieImporter.SessionInfo(
                cookieHeader: validHeader,
                sourceLabel: "Chrome Profile 2"),
        ]
        let stub = ProviderHTTPTransportStub { request in
            let cookieHeader = request.value(forHTTPHeaderField: "Cookie")
            if cookieHeader == rejectedHeader {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil)!
                return (Data("{}".utf8), response)
            }

            #expect(cookieHeader == validHeader)
            let body = "{\"success\": true, \"data\": {\"nak\": \"\(jwt)\"}}"
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(body.utf8), response)
        }

        let context = try await ZoomMateUsageFetcher.requestContext(
            forCookieSessions: sessions,
            cache: ZoomMateBearerTokenCache(),
            timeout: 1,
            transport: stub,
            logger: nil)

        #expect(context.authorization == "Bearer \(jwt)")
        #expect(context.headers["Cookie"] == validHeader)
        #expect(await stub.requests().count == 2)
        let cached = try #require(CookieHeaderCache.load(provider: .zoommate))
        #expect(cached.cookieHeader == validHeader)
        #expect(cached.sourceLabel == "Chrome Profile 2")
    }

    @Test
    func `auto mode does not hide a parse failure behind another Chrome profile`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .zoommate)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        let sessions = [
            ZoomMateCookieImporter.SessionInfo(
                cookieHeader: "_zm_ssid=fake-malformed-response-session",
                sourceLabel: "Chrome Profile 1"),
            ZoomMateCookieImporter.SessionInfo(
                cookieHeader: "_zm_ssid=fake-unused-session",
                sourceLabel: "Chrome Profile 2"),
        ]
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Data("{\"success\": true, \"data\": {}}".utf8), response)
        }

        await #expect {
            _ = try await ZoomMateUsageFetcher.requestContext(
                forCookieSessions: sessions,
                cache: ZoomMateBearerTokenCache(),
                timeout: 1,
                transport: stub,
                logger: nil)
        } throws: { error in
            guard case ZoomMateUsageError.parseFailed = error else { return false }
            return true
        }
        #expect(await stub.requests().count == 1)
        #expect(CookieHeaderCache.load(provider: .zoommate) == nil)
    }

    @Test
    func `failed mint persists nothing`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .zoommate)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), response)
        }

        await #expect {
            _ = try await ZoomMateUsageFetcher.requestContext(
                forCookieHeader: Self.cachedHeader,
                persistingValidatedHeaderAs: "Chrome (Test)",
                cache: ZoomMateBearerTokenCache(),
                timeout: 1,
                transport: stub,
                logger: nil)
        } throws: { error in
            guard case ZoomMateUsageError.invalidCredentials = error else { return false }
            return true
        }
        #expect(CookieHeaderCache.load(provider: .zoommate) == nil)
    }

    @Test
    func `already cached header is not re-persisted`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .zoommate)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        let stub = Self.mintResponseStub(nak: Self.makeJWT())
        _ = try await ZoomMateUsageFetcher.requestContext(
            forCookieHeader: Self.cachedHeader,
            persistingValidatedHeaderAs: nil,
            cache: ZoomMateBearerTokenCache(),
            timeout: 1,
            transport: stub,
            logger: nil)

        #expect(CookieHeaderCache.load(provider: .zoommate) == nil)
    }

    @Test
    func `manual capture mode neither reads nor writes the cookie cache`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .zoommate)
            KeychainCacheStore.setTestStoreForTesting(false)
        }
        CookieHeaderCache.store(
            provider: .zoommate,
            cookieHeader: Self.cachedHeader,
            sourceLabel: "Chrome (Test)")

        let curl = "curl 'https://ai.zoom.us/ai-computer/api/v1/credits/status' " +
            "-H 'authorization: Bearer fake-manual-token' -H 'cookie: session=fake-manual-cookie'"
        let stub = ProviderHTTPTransportStub { request in
            Issue.record("Unexpected network request: \(request.url?.absoluteString ?? "nil")")
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        let fetcher = ZoomMateUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0))

        let context = try await fetcher.resolveRequestContext(
            manualCaptureOverride: curl,
            timeout: 1,
            logger: nil,
            cache: ZoomMateBearerTokenCache(),
            transport: stub)

        #expect(context.authorization == "Bearer fake-manual-token")
        #expect(context.headers["Cookie"] == "session=fake-manual-cookie")
        #expect(CookieHeaderCache.load(provider: .zoommate)?.cookieHeader == Self.cachedHeader)
    }
    #endif
}
