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

    @Test(arguments: [false, true], WebViewPreparationCompletion.allCases)
    func `suspended acquire completion keeps replacement owned`(
        reuse: Bool,
        completion: WebViewPreparationCompletion) async throws
    {
        if self.shouldSkipOnCI() { return }
        for _ in 0..<3 {
            let fixture = WebViewAcquisitionFixture(path: reuse ? .reused : .new)
            defer { fixture.cache.clearAllForTesting() }
            let acquireA = fixture.start()
            let pausedA = await fixture.preparation.next()
            fixture.cache.evict(websiteDataStore: fixture.store)
            let acquireB = fixture.start()
            let pausedB = await fixture.preparation.next()
            #expect(pausedA.webView !== pausedB.webView)
            fixture.preparation.rejectFurtherPreparations = true
            if completion == .cancelledTask { acquireA.task?.cancel() }
            pausedA.finish(completion.result)
            await acquireA.wait()
            acquireA.expectCancellation()
            #expect(fixture.cache.cachedWebViewForTesting(for: fixture.store) === pausedB.webView)
            #expect(fixture.preparation.callCount == 2, "Invalidated work must not retry")
            #expect(fixture.cache.activeAcquisitionCountForTesting == 1)
            fixture.expectCleanup(pausedA.webView)
            pausedB.finish(.success(()))
            await acquireB.wait()
            let leaseB = try #require(acquireB.lease)
            leaseB.release()
            leaseB.release()
            fixture.expectCleanup(pausedB.webView)
            #expect(fixture.cache.entryCount == 0)
            #expect(fixture.cache.activeAcquisitionCountForTesting == 0)
        }
    }

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

extension OpenAIDashboardWebViewCacheTests {
    @Test(arguments: WebViewAcquisitionPath.allCases, [false, true])
    func `task cancellation rejects successful preparation and timeout retry`(
        path: WebViewAcquisitionPath,
        timeout: Bool) async
    {
        if self.shouldSkipOnCI() { return }
        let fixture = WebViewAcquisitionFixture(path: path)
        defer { fixture.cache.clearAllForTesting() }
        let acquire = fixture.start()
        let paused = await fixture.preparation.next()
        fixture.preparation.rejectFurtherPreparations = true
        acquire.task?.cancel()
        paused.finish(timeout ? .failure(URLError(.timedOut)) : .success(()))
        await acquire.wait()
        acquire.expectCancellation()
        #expect(fixture.preparation.callCount == 1)
        #expect(fixture.cache.activeAcquisitionCountForTesting == 0)
        fixture.expectCleanup(paused.webView)
        if path == .temporary {
            #expect(fixture.cache.cachedWebViewForTesting(for: fixture.store) === fixture.seededWebView)
        } else {
            #expect(!fixture.cache.hasCachedEntry(for: fixture.store))
        }
    }

    @Test(arguments: [false, true])
    func `temporary preparation survives normal cached lease release including retry`(retry: Bool) async throws {
        if self.shouldSkipOnCI() { return }
        let fixture = WebViewAcquisitionFixture()
        defer { fixture.cache.clearAllForTesting() }
        let cached = fixture.start()
        let cachedPreparation = await fixture.preparation.next()
        let temporary = fixture.start()
        var paused = await fixture.preparation.next()
        cachedPreparation.finish(.success(()))
        await cached.wait()
        let cachedLease = try #require(cached.lease)
        cachedLease.release()
        #expect(!fixture.cache.hasCachedEntry(for: fixture.store))
        if retry {
            paused.finish(.failure(URLError(.timedOut)))
            let retried = await fixture.preparation.next()
            fixture.expectCleanup(paused.webView)
            #expect(retried.webView !== paused.webView)
            #expect(retried.timeout <= paused.timeout)
            paused = retried
        }
        fixture.preparation.rejectFurtherPreparations = true
        paused.finish(.success(()))
        await temporary.wait()
        let temporaryLease = try #require(temporary.lease)
        #expect(!fixture.cache.hasCachedEntry(for: fixture.store), "Temporary retry must stay temporary")
        temporaryLease.setPreserveLoadedPageOnRelease(true)
        temporaryLease.release()
        temporaryLease.release()
        fixture.expectCleanup(cachedPreparation.webView)
        fixture.expectCleanup(paused.webView)
        #expect(fixture.cache.activeAcquisitionCountForTesting == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func `explicit invalidation reaches temporary preparation after cached lease release`(
        evictAll: Bool,
        timeout: Bool) async throws
    {
        if self.shouldSkipOnCI() { return }
        let fixture = WebViewAcquisitionFixture()
        defer { fixture.cache.clearAllForTesting() }
        let cached = fixture.start()
        let cachedPreparation = await fixture.preparation.next()
        cachedPreparation.finish(.success(()))
        await cached.wait()
        let cachedLease = try #require(cached.lease)
        let temporary = fixture.start()
        let paused = await fixture.preparation.next()
        cachedLease.release()
        if evictAll {
            fixture.cache.evictAll()
        } else {
            fixture.cache.evict(websiteDataStore: fixture.store)
        }
        fixture.expectCleanup(paused.webView)
        fixture.preparation.rejectFurtherPreparations = true
        paused.finish(timeout ? .failure(URLError(.timedOut)) : .success(()))
        await temporary.wait()
        temporary.expectCancellation()
        #expect(fixture.preparation.callCount == 2)
        #expect(fixture.cache.entryCount == 0)
        #expect(fixture.cache.activeAcquisitionCountForTesting == 0)
        fixture.expectCleanup(paused.webView)
    }

    @Test(arguments: [false, true])
    func `explicit invalidation is scoped to its store unless evicting all`(evictAll: Bool) async throws {
        if self.shouldSkipOnCI() { return }
        let fixture = WebViewAcquisitionFixture()
        defer { fixture.cache.clearAllForTesting() }
        let otherStore = WKWebsiteDataStore.nonPersistent()
        let acquireA = fixture.start()
        let pausedA = await fixture.preparation.next()
        let acquireOther = fixture.start(store: otherStore)
        let pausedOther = await fixture.preparation.next()
        if evictAll {
            fixture.cache.evictAll()
        } else {
            fixture.cache.evict(websiteDataStore: fixture.store)
        }
        fixture.preparation.rejectFurtherPreparations = true
        pausedA.finish(.success(()))
        pausedOther.finish(.success(()))
        await acquireA.wait()
        await acquireOther.wait()
        acquireA.expectCancellation()
        if evictAll {
            acquireOther.expectCancellation()
        } else {
            let lease = try #require(acquireOther.lease)
            #expect(fixture.cache.cachedWebViewForTesting(for: otherStore) === lease.webView)
            lease.release()
        }
        fixture.expectCleanup(pausedA.webView)
        fixture.expectCleanup(pausedOther.webView)
        #expect(fixture.cache.entryCount == 0)
        #expect(fixture.cache.activeAcquisitionCountForTesting == 0)
    }

    @Test(arguments: WebViewAcquisitionPath.allCases, [false, true])
    func `active timeout retries once within original deadline`(
        path: WebViewAcquisitionPath,
        success: Bool) async throws
    {
        if self.shouldSkipOnCI() { return }
        let fixture = WebViewAcquisitionFixture(path: path)
        defer { fixture.cache.clearAllForTesting() }
        let acquire = fixture.start()
        let first = await fixture.preparation.next()
        first.finish(.failure(URLError(.timedOut)))
        let retry = await fixture.preparation.next()
        #expect(first.webView !== retry.webView)
        #expect(retry.timeout > 0 && retry.timeout <= first.timeout)
        #expect(!retry.canReuseLoadedPage)
        fixture.expectCleanup(first.webView)
        fixture.preparation.rejectFurtherPreparations = true
        retry.finish(success ? .success(()) : .failure(URLError(.timedOut)))
        await acquire.wait()
        if success {
            let lease = try #require(acquire.lease)
            lease.release()
        } else {
            #expect((acquire.error as? URLError)?.code == .timedOut)
        }
        #expect(fixture.preparation.callCount == 2)
        #expect(fixture.cache.activeAcquisitionCountForTesting == 0)
        fixture.expectCleanup(retry.webView)
    }

    @Test(arguments: WebViewAcquisitionPath.allCases)
    func `disabled timeout retry does not prepare another view`(path: WebViewAcquisitionPath) async {
        if self.shouldSkipOnCI() { return }
        let fixture = WebViewAcquisitionFixture(path: path)
        defer { fixture.cache.clearAllForTesting() }
        let acquire = fixture.start(allowTimeoutRetry: false)
        let paused = await fixture.preparation.next()
        fixture.preparation.rejectFurtherPreparations = true
        paused.finish(.failure(URLError(.timedOut)))
        await acquire.wait()
        #expect((acquire.error as? URLError)?.code == .timedOut)
        #expect(fixture.preparation.callCount == 1)
        #expect(fixture.cache.activeAcquisitionCountForTesting == 0)
        fixture.expectCleanup(paused.webView)
    }

    @Test(arguments: WebViewAcquisitionPath.allCases, [false, true])
    func `ordinary preparation failure and cancellation never retry`(
        path: WebViewAcquisitionPath,
        cancellation: Bool) async
    {
        if self.shouldSkipOnCI() { return }
        let fixture = WebViewAcquisitionFixture(path: path)
        defer { fixture.cache.clearAllForTesting() }
        let acquire = fixture.start()
        let paused = await fixture.preparation.next()
        fixture.preparation.rejectFurtherPreparations = true
        paused.finish(cancellation ? .failure(CancellationError()) : .failure(URLError(.cannotConnectToHost)))
        await acquire.wait()
        if cancellation {
            acquire.expectCancellation()
        } else {
            #expect((acquire.error as? URLError)?.code == .cannotConnectToHost)
        }
        #expect(fixture.preparation.callCount == 1)
        #expect(fixture.cache.activeAcquisitionCountForTesting == 0)
        fixture.expectCleanup(paused.webView)
    }

    @Test(arguments: WebViewAcquisitionPath.allCases)
    func `invalidation during timeout retry preserves replacement`(path: WebViewAcquisitionPath) async throws {
        if self.shouldSkipOnCI() { return }
        let fixture = WebViewAcquisitionFixture(path: path)
        defer { fixture.cache.clearAllForTesting() }
        let acquire = fixture.start()
        let first = await fixture.preparation.next()
        first.finish(.failure(URLError(.timedOut)))
        let retry = await fixture.preparation.next()
        fixture.cache.evict(websiteDataStore: fixture.store)
        let replacement = fixture.start()
        let pausedReplacement = await fixture.preparation.next()
        fixture.preparation.rejectFurtherPreparations = true
        retry.finish(.success(()))
        await acquire.wait()
        acquire.expectCancellation()
        #expect(fixture.cache.cachedWebViewForTesting(for: fixture.store) === pausedReplacement.webView)
        pausedReplacement.finish(.success(()))
        await replacement.wait()
        let lease = try #require(replacement.lease)
        lease.release()
        fixture.expectCleanup(first.webView)
        fixture.expectCleanup(retry.webView)
        fixture.expectCleanup(pausedReplacement.webView)
        #expect(fixture.preparation.callCount == 3)
        #expect(fixture.cache.activeAcquisitionCountForTesting == 0)
    }

    @Test(arguments: WebViewAcquisitionPath.allCases)
    func `lease owns cleanup after cache deallocation`(path: WebViewAcquisitionPath) async throws {
        if self.shouldSkipOnCI() { return }
        var cache: OpenAIDashboardWebViewCache? = OpenAIDashboardWebViewCache()
        let cacheIsAlive = { [weak cache] in cache != nil }
        let store = WKWebsiteDataStore.nonPersistent()
        var hosts: [ObjectIdentifier: AnyObject] = [:]
        cache?.prepareForTesting = { _, _, _ in }
        cache?.didCreateWebViewForTesting = { webView, host in hosts[ObjectIdentifier(webView)] = host }
        if path != .new {
            cache?.cacheEntryForTesting(websiteDataStore: store, isBusy: path == .temporary)
        }
        let url = try #require(URL(string: "https://example.invalid/usage"))
        let lease = try #require(try await cache?.acquire(
            websiteDataStore: store,
            usageURL: url,
            logger: nil,
            preserveLoadedPageOnRelease: true))
        if path == .temporary { cache?.evict(websiteDataStore: store) }
        cache = nil
        #expect(!cacheIsAlive(), "Lease must not retain its cache")
        let host = try #require(hosts[ObjectIdentifier(lease.webView)])
        #expect(!WebKitTeardown.isScheduledForTesting(host))
        lease.release()
        lease.release()
        #expect(WebKitTeardown.isScheduledForTesting(host))
        #expect(OpenAIDashboardWebViewCache.cleanupRequestCountForTesting(host) == 1)
    }

    @Test(arguments: [false, true])
    func `released or evicted lease cannot change replacement ownership`(evict: Bool) async throws {
        if self.shouldSkipOnCI() { return }
        let fixture = WebViewAcquisitionFixture()
        defer { fixture.cache.clearAllForTesting() }
        let first = fixture.start(preserveLoadedPage: true)
        let firstPreparation = await fixture.preparation.next()
        firstPreparation.finish(.success(()))
        await first.wait()
        let firstLease = try #require(first.lease)
        if evict {
            fixture.cache.evict(websiteDataStore: fixture.store)
        } else {
            firstLease.release()
            #expect(fixture.cache.hasPreservedPageForTesting(for: fixture.store))
        }
        let second = fixture.start()
        let secondPreparation = await fixture.preparation.next()
        #expect(secondPreparation.canReuseLoadedPage == !evict)
        #expect((firstPreparation.webView === secondPreparation.webView) == !evict)
        if !evict { firstLease.setPreserveLoadedPageOnRelease(false) }
        firstLease.release()
        firstLease.release()
        #expect(fixture.cache.cachedWebViewForTesting(for: fixture.store) === secondPreparation.webView)
        let secondHost = try #require(fixture.hosts[ObjectIdentifier(secondPreparation.webView)])
        #expect(!WebKitTeardown.isScheduledForTesting(secondHost))
        secondPreparation.finish(.success(()))
        await second.wait()
        let secondLease = try #require(second.lease)
        secondLease.release()
        fixture.expectCleanup(firstPreparation.webView)
        fixture.expectCleanup(secondPreparation.webView)
        #expect(fixture.cache.entryCount == 0)
    }
}

enum WebViewAcquisitionPath: CaseIterable {
    case new, reused, temporary
}

enum WebViewPreparationCompletion: CaseIterable {
    case failure, cancellation, timeout, success, cancelledTask

    var result: Result<Void, Error> {
        switch self {
        case .failure: .failure(URLError(.cannotConnectToHost))
        case .cancellation: .failure(CancellationError())
        case .timeout: .failure(URLError(.timedOut))
        case .success, .cancelledTask: .success(())
        }
    }
}

@MainActor
private final class WebViewAcquisitionFixture {
    let cache = OpenAIDashboardWebViewCache()
    let store = WKWebsiteDataStore.nonPersistent()
    let preparation = WebViewPreparationGate()
    var hosts: [ObjectIdentifier: AnyObject] = [:]
    var seededWebView: WKWebView?

    init(path: WebViewAcquisitionPath = .new) {
        self.cache.prepareForTesting = self.preparation.prepare
        self.cache.didCreateWebViewForTesting = { [weak self] webView, host in
            self?.hosts[ObjectIdentifier(webView)] = host
        }
        if path != .new {
            self.seededWebView = self.cache.cacheEntryForTesting(
                websiteDataStore: self.store,
                isBusy: path == .temporary)
        }
    }

    func start(
        store: WKWebsiteDataStore? = nil,
        allowTimeoutRetry: Bool = true,
        preserveLoadedPage: Bool = false) -> WebViewAcquireResult
    {
        let result = WebViewAcquireResult()
        let store = store ?? self.store
        result.task = Task { @MainActor [cache] in
            do {
                result.lease = try await cache.acquire(
                    websiteDataStore: store,
                    usageURL: URL(string: "https://example.invalid/usage")!,
                    logger: nil,
                    allowTimeoutRetry: allowTimeoutRetry,
                    preserveLoadedPageOnRelease: preserveLoadedPage)
            } catch {
                result.error = error
            }
        }
        return result
    }

    func expectCleanup(_ webView: WKWebView, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let host = self.hosts[ObjectIdentifier(webView)] else {
            Issue.record("Missing host", sourceLocation: sourceLocation)
            return
        }
        #expect(WebKitTeardown.isScheduledForTesting(host), sourceLocation: sourceLocation)
        #expect(OpenAIDashboardWebViewCache.cleanupRequestCountForTesting(host) == 1, sourceLocation: sourceLocation)
    }
}

@MainActor
private final class WebViewAcquireResult {
    var lease: OpenAIDashboardWebViewLease?
    var error: Error?
    var task: Task<Void, Never>?

    func wait() async {
        await self.task?.value
        self.task = nil
    }

    func expectCancellation(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(self.lease == nil, sourceLocation: sourceLocation)
        #expect(self.error is CancellationError, sourceLocation: sourceLocation)
        self.lease?.release()
    }
}

@MainActor
private final class WebViewPreparationGate {
    @MainActor
    struct Preparation {
        let webView: WKWebView
        let timeout: TimeInterval
        let canReuseLoadedPage: Bool
        let finish: (Result<Void, Error>) -> Void
    }

    var rejectFurtherPreparations = false
    private(set) var callCount = 0
    private var pending: [Preparation] = []
    private var waiter: CheckedContinuation<Preparation, Never>?

    func prepare(_ webView: WKWebView, timeout: TimeInterval, canReuseLoadedPage: Bool) async throws {
        self.callCount += 1
        if self.rejectFurtherPreparations { throw URLError(.cannotConnectToHost) }
        try await withCheckedThrowingContinuation { continuation in
            let preparation = Preparation(
                webView: webView,
                timeout: timeout,
                canReuseLoadedPage: canReuseLoadedPage,
                finish: { continuation.resume(with: $0) })
            if let waiter = self.waiter {
                self.waiter = nil
                waiter.resume(returning: preparation)
            } else {
                self.pending.append(preparation)
            }
        }
    }

    func next() async -> Preparation {
        if !self.pending.isEmpty { return self.pending.removeFirst() }
        return await withCheckedContinuation { self.waiter = $0 }
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
