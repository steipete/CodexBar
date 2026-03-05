import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct PerplexityCookieCacheTests {
    private static let testToken = "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0.fake-test-token"
    private static let testCookieName = PerplexityCookieHeader.defaultSessionCookieName

    // MARK: - Cache round-trip

    @Test
    func cacheRoundTripProducesValidCookieOverride() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .perplexity)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        CookieHeaderCache.store(
            provider: .perplexity,
            cookieHeader: "\(Self.testCookieName)=\(Self.testToken)",
            sourceLabel: "web")

        let cached = CookieHeaderCache.load(provider: .perplexity)
        #expect(cached != nil)
        #expect(cached?.sourceLabel == "web")

        let override = PerplexityCookieHeader.override(from: cached?.cookieHeader)
        #expect(override?.name == Self.testCookieName)
        #expect(override?.token == Self.testToken)
    }

    // MARK: - isAvailable returns true when cache has entry

    @Test
    func isAvailableReturnsTrueWhenCachePopulated() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .perplexity)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        // With no cache and no other sources, load should return nil
        let beforeStore = CookieHeaderCache.load(provider: .perplexity)
        #expect(beforeStore == nil)

        // After storing, cache should be available
        CookieHeaderCache.store(
            provider: .perplexity,
            cookieHeader: "\(Self.testCookieName)=\(Self.testToken)",
            sourceLabel: "web")

        let afterStore = CookieHeaderCache.load(provider: .perplexity)
        #expect(afterStore != nil)
    }

    // MARK: - Cache cleared on invalidToken

    @Test
    func cacheClearedOnInvalidToken() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .perplexity)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        CookieHeaderCache.store(
            provider: .perplexity,
            cookieHeader: "\(Self.testCookieName)=\(Self.testToken)",
            sourceLabel: "web")

        // Verify it's cached
        #expect(CookieHeaderCache.load(provider: .perplexity) != nil)

        // Simulate what fetch() does on invalidToken: clear the cache
        CookieHeaderCache.clear(provider: .perplexity)

        #expect(CookieHeaderCache.load(provider: .perplexity) == nil)
    }

    // MARK: - Cache NOT cleared on non-auth errors

    @Test
    func cacheNotClearedOnNetworkError() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .perplexity)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        CookieHeaderCache.store(
            provider: .perplexity,
            cookieHeader: "\(Self.testCookieName)=\(Self.testToken)",
            sourceLabel: "web")

        // Simulate a networkError — cache should NOT be cleared
        let error = PerplexityAPIError.networkError("timeout")
        switch error {
        case .invalidToken:
            CookieHeaderCache.clear(provider: .perplexity)
        default:
            break // non-auth errors do not clear cache
        }

        #expect(CookieHeaderCache.load(provider: .perplexity) != nil)
    }

    @Test
    func cacheNotClearedOnAPIError() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .perplexity)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        CookieHeaderCache.store(
            provider: .perplexity,
            cookieHeader: "\(Self.testCookieName)=\(Self.testToken)",
            sourceLabel: "web")

        // Simulate an apiError (e.g. HTTP 500) — cache should NOT be cleared
        let error = PerplexityAPIError.apiError("HTTP 500")
        switch error {
        case .invalidToken:
            CookieHeaderCache.clear(provider: .perplexity)
        default:
            break // non-auth errors do not clear cache
        }

        #expect(CookieHeaderCache.load(provider: .perplexity) != nil)
    }

    // MARK: - Bare token stored as default cookie name

    @Test
    func bareTokenRoundTripsWithDefaultCookieName() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .perplexity)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        // Store with default cookie name format
        CookieHeaderCache.store(
            provider: .perplexity,
            cookieHeader: "\(Self.testCookieName)=\(Self.testToken)",
            sourceLabel: "web")

        let cached = CookieHeaderCache.load(provider: .perplexity)
        let override = PerplexityCookieHeader.override(from: cached?.cookieHeader)
        #expect(override?.name == Self.testCookieName)
        #expect(override?.token == Self.testToken)
    }
}
