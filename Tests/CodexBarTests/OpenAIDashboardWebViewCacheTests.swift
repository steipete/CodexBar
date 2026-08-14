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
    private func shouldSkipOnCI() -> Bool {
        let env = ProcessInfo.processInfo.environment
        return env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true"
    }

    // MARK: - Data Store Identity Tests

    @Test
    func `navigation retry uses only remaining shared deadline`() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let deadline = start.addingTimeInterval(10)

        let remaining = try OpenAIDashboardWebViewCache.remainingNavigationTimeout(
            until: deadline,
            now: start.addingTimeInterval(9.75))

        #expect(remaining == 0.25)
    }

    @Test
    func `navigation retry refuses expired shared deadline`() {
        let deadline = Date(timeIntervalSinceReferenceDate: 1000)

        do {
            _ = try OpenAIDashboardWebViewCache.remainingNavigationTimeout(
                until: deadline,
                now: deadline)
            Issue.record("Expected deadline timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `WKWebsiteDataStore should return same instance for same email`() {
        if self.shouldSkipOnCI() {
            return
        }
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

    @Test
    func `same email profile homes use distinct website data stores`() {
        OpenAIDashboardWebsiteDataStore.clearCacheForTesting()
        defer { OpenAIDashboardWebsiteDataStore.clearCacheForTesting() }

        let profileA = CookieHeaderCache.Scope.profileHome("/tmp/codex-profile-a")
        let profileB = CookieHeaderCache.Scope.profileHome("/tmp/codex-profile-b")
        let storeA = OpenAIDashboardWebsiteDataStore.store(
            forAccountEmail: "shared@example.com",
            scope: profileA)
        let storeAAgain = OpenAIDashboardWebsiteDataStore.store(
            forAccountEmail: "SHARED@example.com",
            scope: profileA)
        let storeB = OpenAIDashboardWebsiteDataStore.store(
            forAccountEmail: "shared@example.com",
            scope: profileB)
        let liveStore = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: "shared@example.com")

        #expect(storeA === storeAAgain)
        #expect(storeA !== storeB)
        #expect(storeA !== liveStore)
        #expect(storeB !== liveStore)
        #expect(storeA.identifier != storeB.identifier)
        #expect(storeA.identifier != liveStore.identifier)
        #expect(storeB.identifier != liveStore.identifier)
    }

    @Test
    func `live website data store preserves legacy email identifier`() {
        OpenAIDashboardWebsiteDataStore.clearCacheForTesting()
        defer { OpenAIDashboardWebsiteDataStore.clearCacheForTesting() }

        let store = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: " SHARED@EXAMPLE.COM ")

        #expect(store.identifier?.uuidString == "CC61BD27-6855-439F-9D11-F470B7977B90")
    }

    // MARK: - WebView Reuse Tests

    @Test
    func `WebView is destroyed after release unless the page is preserved`() async throws {
        if self.shouldSkipOnCI() {
            return
        }
        let cache = OpenAIDashboardWebViewCache()
        let store = WKWebsiteDataStore.nonPersistent()
        let url = try #require(URL(string: "about:blank"))

        // First acquire
        let lease1 = try await cache.acquire(
            websiteDataStore: store,
            usageURL: url,
            logger: nil)
        let webView1 = lease1.webView

        lease1.release()

        #expect(!cache.hasCachedEntry(for: store), "Unpreserved WebView should be evicted on release")
        #expect(cache.entryCount == 0, "Should have no cached entries after release")

        let lease2 = try await cache.acquire(
            websiteDataStore: store,
            usageURL: url,
            logger: nil)
        let webView2 = lease2.webView

        #expect(webView1 !== webView2, "Next acquire should create a fresh WebView")

        lease2.release()
        cache.clearAllForTesting()
    }

    @Test
    func `Different data stores should have separate cached WebViews`() async throws {
        if self.shouldSkipOnCI() {
            return
        }
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
        #expect(cache.entryCount == 0, "Unpreserved releases should evict both WebViews")

        cache.clearAllForTesting()
    }

    // MARK: - Idle Timeout / Pruning Tests

    @Test
    func `WebView should be pruned after idle timeout`() {
        if self.shouldSkipOnCI() {
            return
        }
        let cache = OpenAIDashboardWebViewCache()
        let store = WKWebsiteDataStore.nonPersistent()
        cache.cacheEntryForTesting(websiteDataStore: store)

        #expect(cache.hasCachedEntry(for: store), "Should be cached immediately after release")

        // Simulate time passing beyond the configured idle timeout.
        let futureTime = Date().addingTimeInterval(cache.idleTimeoutForTesting + 5)
        cache.pruneForTesting(now: futureTime)

        #expect(!cache.hasCachedEntry(for: store), "Should be pruned after idle timeout")
        #expect(cache.entryCount == 0, "Should have no cached entries after prune")
    }

    @Test
    func `Recently used WebView should not be pruned`() {
        if self.shouldSkipOnCI() {
            return
        }
        let cache = OpenAIDashboardWebViewCache()
        let store = WKWebsiteDataStore.nonPersistent()
        cache.cacheEntryForTesting(websiteDataStore: store)

        // Simulate time passing comfortably within the configured idle timeout.
        let nearFutureTime = Date().addingTimeInterval(max(1, cache.idleTimeoutForTesting / 2))
        cache.pruneForTesting(now: nearFutureTime)

        #expect(cache.hasCachedEntry(for: store), "Should still be cached within idle timeout")
        cache.clearAllForTesting()
    }

    @Test
    func `Preserved page handoff is consumed only once`() {
        if self.shouldSkipOnCI() {
            return
        }
        let cache = OpenAIDashboardWebViewCache()
        let store = WKWebsiteDataStore.nonPersistent()
        cache.cacheEntryForTesting(websiteDataStore: store)
        cache.markPreservedPageForTesting(
            websiteDataStore: store,
            expiresAt: Date().addingTimeInterval(cache.preservedPageHandoffTimeoutForTesting))

        #expect(cache.hasPreservedPageForTesting(for: store), "Expected preserved page handoff to be armed")
        #expect(cache.consumePreservedPageForTesting(websiteDataStore: store), "First acquire should reuse handoff")
        #expect(
            !cache.consumePreservedPageForTesting(websiteDataStore: store),
            "Second acquire should not keep reusing preserved page")

        cache.clearAllForTesting()
    }

    @Test
    func `Expired preserved page is cleared before idle eviction`() {
        if self.shouldSkipOnCI() {
            return
        }
        let cache = OpenAIDashboardWebViewCache()
        let store = WKWebsiteDataStore.nonPersistent()
        cache.cacheEntryForTesting(websiteDataStore: store)
        cache.markPreservedPageForTesting(
            websiteDataStore: store,
            expiresAt: Date().addingTimeInterval(1))

        let afterExpiry = Date().addingTimeInterval(cache.preservedPageHandoffTimeoutForTesting + 1)
        cache.pruneForTesting(now: afterExpiry)

        #expect(!cache.hasPreservedPageForTesting(for: store), "Expired preserved page should be cleared")
        #expect(!cache.hasCachedEntry(for: store), "Expired handoff should evict the WebView")

        cache.clearAllForTesting()
    }

    @Test
    func `Preserved page expiry is scheduled without future cache activity`() async {
        if self.shouldSkipOnCI() {
            return
        }
        let cache = OpenAIDashboardWebViewCache()
        let store = WKWebsiteDataStore.nonPersistent()
        cache.cacheEntryForTesting(websiteDataStore: store)
        cache.markPreservedPageForTesting(
            websiteDataStore: store,
            expiresAt: Date().addingTimeInterval(0.2))

        #expect(cache.hasPreservedPageForTesting(for: store), "Expected preserved page handoff to be armed")

        let deadline = Date().addingTimeInterval(2)
        while cache.hasCachedEntry(for: store), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }

        #expect(!cache.hasCachedEntry(for: store), "Expected scheduled expiry to evict the preserved WebView")

        cache.clearAllForTesting()
    }

    @Test
    func `Unpreserved release evicts immediately without waiting for idle prune`() async throws {
        if self.shouldSkipOnCI() {
            return
        }
        let cache = OpenAIDashboardWebViewCache(idleTimeout: 5)
        let store = WKWebsiteDataStore.nonPersistent()
        let url = try #require(URL(string: "about:blank"))

        var lease: OpenAIDashboardWebViewLease? = try await cache.acquire(
            websiteDataStore: store,
            usageURL: url,
            logger: nil)
        lease?.release()
        lease = nil

        #expect(!cache.hasCachedEntry(for: store), "Unpreserved release should evict immediately")

        cache.clearAllForTesting()
    }

    @Test
    func `Preserved handoff keeps the WebView only until expiry`() async throws {
        if self.shouldSkipOnCI() {
            return
        }
        let cache = OpenAIDashboardWebViewCache(idleTimeout: 5)
        let store = WKWebsiteDataStore.nonPersistent()
        let url = try #require(URL(string: "about:blank"))

        let lease = try await cache.acquire(
            websiteDataStore: store,
            usageURL: url,
            logger: nil,
            preserveLoadedPageOnRelease: true)
        lease.setPreserveLoadedPageOnRelease(true)
        lease.release()

        #expect(cache.hasCachedEntry(for: store), "Preserved handoff should keep the WebView briefly")
        #expect(cache.hasPreservedPageForTesting(for: store))

        cache.clearAllForTesting()
    }

    @Test
    func `Reused page reset clears one shot scraper globals`() async throws {
        if self.shouldSkipOnCI() {
            return
        }
        let cache = OpenAIDashboardWebViewCache()
        let store = WKWebsiteDataStore.nonPersistent()
        let url = try #require(URL(string: "about:blank"))

        let lease = try await cache.acquire(
            websiteDataStore: store,
            usageURL: url,
            logger: nil)

        _ = try await lease.webView.evaluateJavaScript(
            """
            window.__codexbarDidScrollToCredits = true;
            window.__codexbarUsageBreakdownJSON = '[{"day":"2026-04-19"}]';
            window.__codexbarUsageBreakdownDebug = 'debug';
            true;
            """)

        #expect(await cache.resetReusablePageStateForTesting(lease.webView))

        let reset = try await lease.webView.evaluateJavaScript(
            """
            typeof window.__codexbarDidScrollToCredits === 'undefined' &&
            typeof window.__codexbarUsageBreakdownJSON === 'undefined' &&
            typeof window.__codexbarUsageBreakdownDebug === 'undefined'
            """) as? Bool

        #expect(reset == true, "Expected one-shot scraper globals to be cleared before reuse")

        lease.release()
        cache.clearAllForTesting()
    }

    // MARK: - Eviction Tests

    @Test
    func `Evict should remove specific WebView from cache`() async throws {
        if self.shouldSkipOnCI() {
            return
        }
        let cache = OpenAIDashboardWebViewCache()
        let store1 = WKWebsiteDataStore.nonPersistent()
        let store2 = WKWebsiteDataStore.nonPersistent()
        let url = try #require(URL(string: "about:blank"))

        // Cache two WebViews
        let lease1 = try await cache.acquire(websiteDataStore: store1, usageURL: url, logger: nil)
        lease1.release()
        cache.cacheEntryForTesting(websiteDataStore: store1)
        let lease2 = try await cache.acquire(websiteDataStore: store2, usageURL: url, logger: nil)
        lease2.release()
        cache.cacheEntryForTesting(websiteDataStore: store2)

        #expect(cache.entryCount == 2, "Should have two cached entries")

        // Evict only the first one
        cache.evict(websiteDataStore: store1)

        #expect(!cache.hasCachedEntry(for: store1), "First store should be evicted")
        #expect(cache.hasCachedEntry(for: store2), "Second store should still be cached")
        #expect(cache.entryCount == 1, "Should have one cached entry remaining")

        cache.clearAllForTesting()
    }

    @Test
    func `Evicted WebView should not be reused on next acquire`() async throws {
        if self.shouldSkipOnCI() {
            return
        }
        let cache = OpenAIDashboardWebViewCache()
        let store = WKWebsiteDataStore.nonPersistent()
        let url = try #require(URL(string: "about:blank"))

        let lease1 = try await cache.acquire(websiteDataStore: store, usageURL: url, logger: nil)
        let webView1 = lease1.webView
        lease1.release()

        cache.evict(websiteDataStore: store)

        let lease2 = try await cache.acquire(websiteDataStore: store, usageURL: url, logger: nil)
        let webView2 = lease2.webView

        #expect(webView1 !== webView2, "Acquire after eviction should create a fresh WebView")

        lease2.release()
        cache.clearAllForTesting()
    }

    @Test
    func `Evict all should remove every cached WebView`() async throws {
        if self.shouldSkipOnCI() {
            return
        }
        let cache = OpenAIDashboardWebViewCache()
        let store1 = WKWebsiteDataStore.nonPersistent()
        let store2 = WKWebsiteDataStore.nonPersistent()
        let url = try #require(URL(string: "about:blank"))

        let lease1 = try await cache.acquire(websiteDataStore: store1, usageURL: url, logger: nil)
        lease1.release()
        cache.cacheEntryForTesting(websiteDataStore: store1)
        let lease2 = try await cache.acquire(websiteDataStore: store2, usageURL: url, logger: nil)
        lease2.release()
        cache.cacheEntryForTesting(websiteDataStore: store2)

        #expect(cache.entryCount == 2, "Should have two cached entries")

        cache.evictAll()

        #expect(cache.entryCount == 0, "Evict all should remove every cached entry")
        #expect(!cache.hasCachedEntry(for: store1), "First store should be evicted")
        #expect(!cache.hasCachedEntry(for: store2), "Second store should be evicted")
    }

    @Test
    func `Evict idle removes idle WebViews without interrupting busy WebViews`() {
        if self.shouldSkipOnCI() {
            return
        }
        let cache = OpenAIDashboardWebViewCache()
        let idleStore = WKWebsiteDataStore.nonPersistent()
        let busyStore = WKWebsiteDataStore.nonPersistent()

        cache.cacheEntryForTesting(websiteDataStore: idleStore)
        cache.cacheEntryForTesting(websiteDataStore: busyStore, isBusy: true)

        cache.evictIdle()

        #expect(!cache.hasCachedEntry(for: idleStore), "Idle WebView should be evicted")
        #expect(cache.hasCachedEntry(for: busyStore), "Busy WebView should remain cached")
        #expect(cache.entryCount == 1, "Only the busy entry should remain")

        cache.clearAllForTesting()
    }

    @Test
    func `Memory pressure monitor evicts idle shared WebViews without interrupting busy WebViews`() {
        if self.shouldSkipOnCI() {
            return
        }
        let cache = OpenAIDashboardWebViewCache.shared
        cache.clearAllForTesting()
        defer { cache.clearAllForTesting() }

        let idleStore = WKWebsiteDataStore.nonPersistent()
        let busyStore = WKWebsiteDataStore.nonPersistent()

        cache.cacheEntryForTesting(websiteDataStore: idleStore)
        cache.cacheEntryForTesting(websiteDataStore: busyStore, isBusy: true)

        #expect(cache.entryCount == 2, "Should have one idle entry and one busy entry before pressure")

        let monitor = MemoryPressureMonitor()
        monitor.handleMemoryPressureForTesting(isWarning: true, isCritical: false)

        #expect(!cache.hasCachedEntry(for: idleStore), "Memory pressure should evict the idle shared WebView")
        #expect(cache.hasCachedEntry(for: busyStore), "Memory pressure should not interrupt a busy shared WebView")
        #expect(cache.entryCount == 1, "Only the busy shared entry should remain")
    }

    @Test
    func `Memory pressure malloc relief runs off the main thread`() async {
        let probe = MemoryPressureThreadProbe()
        let monitor = MemoryPressureMonitor(releaseFreeMallocPages: {
            probe.recordCurrentThread()
        })

        monitor.handleMemoryPressureForTesting(isWarning: true, isCritical: false)

        let completed = await Task.detached {
            probe.wait(timeout: .now() + 2)
        }.value
        #expect(completed)
        #expect(probe.wasMainThread == false)
    }

    // MARK: - Busy WebView Tests

    @Test
    func `Busy WebView should create temporary WebView for concurrent access`() async throws {
        if self.shouldSkipOnCI() {
            return
        }
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

    @Test
    func `Multiple sequential fetches destroy the WebView after each release`() async throws {
        if self.shouldSkipOnCI() {
            return
        }
        let cache = OpenAIDashboardWebViewCache()
        let store = WKWebsiteDataStore.nonPersistent()
        let url = try #require(URL(string: "about:blank"))

        var webViews: [WKWebView] = []

        for _ in 0..<3 {
            let lease = try await cache.acquire(
                websiteDataStore: store,
                usageURL: url,
                logger: nil)
            webViews.append(lease.webView)
            lease.release()
            #expect(cache.entryCount == 0, "Each unpreserved release should evict the WebView")
        }

        #expect(webViews[0] !== webViews[1])
        #expect(webViews[1] !== webViews[2])

        cache.clearAllForTesting()
    }

    // MARK: - Integration Test with Real Data Store Factory

    @Test
    func `Sequential fetches with OpenAIDashboardWebsiteDataStore should reuse WebView`() async throws {
        if self.shouldSkipOnCI() {
            return
        }
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

        #expect(webViews[0] !== webViews[1])
        #expect(webViews[1] !== webViews[2])
        #expect(cache.entryCount == 0, "Unpreserved sequential fetches should not keep a WebView resident")

        cache.clearAllForTesting()
        OpenAIDashboardWebsiteDataStore.clearCacheForTesting()
    }
}

private final class MemoryPressureThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var recordedMainThread: Bool?

    var wasMainThread: Bool? {
        self.lock.withLock { self.recordedMainThread }
    }

    func recordCurrentThread() {
        self.lock.withLock {
            self.recordedMainThread = Thread.isMainThread
        }
        self.semaphore.signal()
    }

    func wait(timeout: DispatchTime) -> Bool {
        self.semaphore.wait(timeout: timeout) == .success
    }
}
