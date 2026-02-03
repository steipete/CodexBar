import Foundation
import Testing
import WebKit
@testable import CodexBar
@testable import CodexBarCore

/// Tests for OpenAIDashboardWebViewCache to verify WebView reuse behavior.
///
/// Background: The cache should keep WebViews alive after use to avoid re-downloading
/// the ChatGPT SPA bundle on every refresh. Previously, WebViews were destroyed after
/// each fetch, causing 15+ GB of network traffic over time. See GitHub issues #269, #251.
@MainActor
@Suite(.serialized)
struct OpenAIDashboardWebViewCacheTests {
    // MARK: - Data Store Identity Tests

    @Test("WKWebsiteDataStore should return same instance for same email")
    func dataStoreReturnsSameInstance() {
        OpenAIDashboardWebsiteDataStore.clearCacheForTesting()

        let store1 = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: "test@example.com")
        let store2 = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: "test@example.com")
        let store3 = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: "TEST@EXAMPLE.COM") // Case insensitive

        #expect(store1 === store2, "Same email should return same instance")
        #expect(store1 === store3, "Email comparison should be case-insensitive")

        // Different email should return different instance
        let store4 = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: "other@example.com")
        #expect(store1 !== store4, "Different emails should return different instances")

        OpenAIDashboardWebsiteDataStore.clearCacheForTesting()
    }

    // MARK: - WebView Reuse Tests

    @Test("WebView should be cached after release, not destroyed")
    func webViewCachedAfterRelease() async throws {
        let cache = OpenAIDashboardWebViewCache()
        let store = WKWebsiteDataStore.nonPersistent()
        let url = try #require(URL(string: "about:blank"))

        // First acquire
        let lease1 = try await cache.acquire(
            websiteDataStore: store,
            usageURL: url,
            logger: nil)
        let webView1 = lease1.webView

        // Release - should hide, not destroy
        lease1.release()

        // Entry should still be in cache
        #expect(cache.hasCachedEntry(for: store), "WebView should remain cached after release")
        #expect(cache.entryCount == 1, "Should have exactly one cached entry")

        // Second acquire should reuse the same WebView
        let lease2 = try await cache.acquire(
            websiteDataStore: store,
            usageURL: url,
            logger: nil)
        let webView2 = lease2.webView

        #expect(webView1 === webView2, "Should reuse the same WebView instance")

        lease2.release()
        cache.clearAllForTesting()
    }

    @Test("Different data stores should have separate cached WebViews")
    func separateCachesPerDataStore() async throws {
        let cache = OpenAIDashboardWebViewCache()
        let store1 = WKWebsiteDataStore.nonPersistent()
        let store2 = WKWebsiteDataStore.nonPersistent()
        let url = try #require(URL(string: "about:blank"))

        // Acquire for first store
        let lease1 = try await cache.acquire(
            websiteDataStore: store1,
            usageURL: url,
            logger: nil)
        let webView1 = lease1.webView
        lease1.release()

        // Acquire for second store
        let lease2 = try await cache.acquire(
            websiteDataStore: store2,
            usageURL: url,
            logger: nil)
        let webView2 = lease2.webView
        lease2.release()

        #expect(webView1 !== webView2, "Different data stores should have different WebViews")
        #expect(cache.entryCount == 2, "Should have two cached entries")

        cache.clearAllForTesting()
    }

    // MARK: - Idle Timeout / Pruning Tests

    @Test("WebView should be pruned after idle timeout")
    func webViewPrunedAfterIdleTimeout() async throws {
        let cache = OpenAIDashboardWebViewCache()
        let store = WKWebsiteDataStore.nonPersistent()
        let url = try #require(URL(string: "about:blank"))

        // Acquire and release
        let lease = try await cache.acquire(
            websiteDataStore: store,
            usageURL: url,
            logger: nil)
        lease.release()

        #expect(cache.hasCachedEntry(for: store), "Should be cached immediately after release")

        // Simulate time passing beyond idle timeout (10 minutes + buffer)
        let futureTime = Date().addingTimeInterval(11 * 60)
        cache.pruneForTesting(now: futureTime)

        #expect(!cache.hasCachedEntry(for: store), "Should be pruned after idle timeout")
        #expect(cache.entryCount == 0, "Should have no cached entries after prune")
    }

    @Test("Recently used WebView should not be pruned")
    func recentlyUsedWebViewNotPruned() async throws {
        let cache = OpenAIDashboardWebViewCache()
        let store = WKWebsiteDataStore.nonPersistent()
        let url = try #require(URL(string: "about:blank"))

        // Acquire and release
        let lease = try await cache.acquire(
            websiteDataStore: store,
            usageURL: url,
            logger: nil)
        lease.release()

        // Simulate time passing within idle timeout (5 minutes)
        let nearFutureTime = Date().addingTimeInterval(5 * 60)
        cache.pruneForTesting(now: nearFutureTime)

        #expect(cache.hasCachedEntry(for: store), "Should still be cached within idle timeout")
    }

    // MARK: - Eviction Tests

    @Test("Evict should remove specific WebView from cache")
    func evictRemovesSpecificWebView() async throws {
        let cache = OpenAIDashboardWebViewCache()
        let store1 = WKWebsiteDataStore.nonPersistent()
        let store2 = WKWebsiteDataStore.nonPersistent()
        let url = try #require(URL(string: "about:blank"))

        // Cache two WebViews
        let lease1 = try await cache.acquire(websiteDataStore: store1, usageURL: url, logger: nil)
        lease1.release()
        let lease2 = try await cache.acquire(websiteDataStore: store2, usageURL: url, logger: nil)
        lease2.release()

        #expect(cache.entryCount == 2, "Should have two cached entries")

        // Evict only the first one
        cache.evict(websiteDataStore: store1)

        #expect(!cache.hasCachedEntry(for: store1), "First store should be evicted")
        #expect(cache.hasCachedEntry(for: store2), "Second store should still be cached")
        #expect(cache.entryCount == 1, "Should have one cached entry remaining")

        cache.clearAllForTesting()
    }

    // MARK: - Busy WebView Tests

    @Test("Busy WebView should create temporary WebView for concurrent access")
    func busyWebViewCreatesTemporary() async throws {
        let cache = OpenAIDashboardWebViewCache()
        let store = WKWebsiteDataStore.nonPersistent()
        let url = try #require(URL(string: "about:blank"))

        var logMessages: [String] = []
        let logger: (String) -> Void = { logMessages.append($0) }

        // Acquire first (don't release yet - keeps it busy)
        let lease1 = try await cache.acquire(
            websiteDataStore: store,
            usageURL: url,
            logger: logger)
        let webView1 = lease1.webView

        // Try to acquire again while first is busy
        let lease2 = try await cache.acquire(
            websiteDataStore: store,
            usageURL: url,
            logger: logger)
        let webView2 = lease2.webView

        #expect(webView1 !== webView2, "Should create temporary WebView when cached one is busy")
        #expect(
            logMessages.contains { $0.contains("Cached WebView busy") },
            "Should log that cached WebView is busy")

        lease1.release()
        lease2.release()
        cache.clearAllForTesting()
    }

    // MARK: - Network Traffic Regression Prevention

    @Test("Multiple sequential fetches should reuse same WebView (network optimization)")
    func sequentialFetchesReuseWebView() async throws {
        let cache = OpenAIDashboardWebViewCache()
        let store = WKWebsiteDataStore.nonPersistent()
        let url = try #require(URL(string: "about:blank"))

        var webViews: [WKWebView] = []

        // Simulate 5 sequential fetches (like 5 refresh cycles)
        for _ in 0..<5 {
            let lease = try await cache.acquire(
                websiteDataStore: store,
                usageURL: url,
                logger: nil)
            webViews.append(lease.webView)
            lease.release()
        }

        // All should be the same WebView instance
        let firstWebView = webViews[0]
        for (index, webView) in webViews.enumerated() {
            #expect(
                webView === firstWebView,
                "Fetch \(index + 1) should reuse the same WebView instance")
        }

        // Only one entry should exist in cache
        #expect(cache.entryCount == 1, "Should maintain single cached entry across all fetches")

        cache.clearAllForTesting()
    }

    // MARK: - Integration Test with Real Data Store Factory

    @Test("Sequential fetches with OpenAIDashboardWebsiteDataStore should reuse WebView")
    func sequentialFetchesWithRealDataStoreFactory() async throws {
        OpenAIDashboardWebsiteDataStore.clearCacheForTesting()
        let cache = OpenAIDashboardWebViewCache()
        let url = try #require(URL(string: "about:blank"))
        let email = "integration-test@example.com"

        var webViews: [WKWebView] = []

        // Simulate 3 sequential fetches using the real data store factory
        // This tests that OpenAIDashboardWebsiteDataStore returns stable instances
        for _ in 0..<3 {
            let store = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: email)
            let lease = try await cache.acquire(
                websiteDataStore: store,
                usageURL: url,
                logger: nil)
            webViews.append(lease.webView)
            lease.release()
        }

        // All should be the same WebView instance
        let firstWebView = webViews[0]
        for (index, webView) in webViews.enumerated() {
            #expect(
                webView === firstWebView,
                "Fetch \(index + 1) with real data store factory should reuse same WebView")
        }

        #expect(cache.entryCount == 1, "Should have single cached entry")

        cache.clearAllForTesting()
        OpenAIDashboardWebsiteDataStore.clearCacheForTesting()
    }
}
