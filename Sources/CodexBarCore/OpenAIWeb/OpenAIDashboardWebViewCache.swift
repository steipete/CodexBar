#if os(macOS)
import AppKit
import Foundation
import WebKit

struct OpenAIDashboardWebViewLease {
    let webView: WKWebView
    let log: (String) -> Void
    let setPreserveLoadedPageOnRelease: (Bool) -> Void
    let release: () -> Void
}

@MainActor
final class OpenAIDashboardWebViewCache {
    static let shared = OpenAIDashboardWebViewCache()
    fileprivate static let log = CodexBarLog.logger(LogCategories.provider(.openai, scope: "webview"))

    private final class ReleaseState {
        var preserveLoadedPageOnRelease: Bool
        var isReleased = false

        init(preserveLoadedPageOnRelease: Bool) {
            self.preserveLoadedPageOnRelease = preserveLoadedPageOnRelease
        }
    }

    private final class Acquisition {
        let key: ObjectIdentifier
        var entry: Entry?
        var isInvalidated = false

        init(key: ObjectIdentifier) {
            self.key = key
        }

        func checkCancellation() throws {
            try Task.checkCancellation()
            if self.isInvalidated { throw CancellationError() }
        }
    }

    @MainActor
    private final class NavigationCancellationState {
        private weak var webView: WKWebView?
        private var delegate: NavigationDelegate?
        private var isCancelled = false

        func install(webView: WKWebView, delegate: NavigationDelegate) {
            self.webView = webView
            self.delegate = delegate
            if self.isCancelled {
                self.cancel()
            }
        }

        func cancel() {
            self.isCancelled = true
            guard let webView, let delegate else { return }
            delegate.cancel()
            if webView.codexNavigationDelegate === delegate {
                webView.stopLoading()
                webView.navigationDelegate = nil
                webView.codexNavigationDelegate = nil
            }
            self.delegate = nil
            self.webView = nil
        }
    }

    @MainActor
    private final class Entry {
        let webView: WKWebView
        let host: OffscreenWebViewHost
        var lastUsedAt: Date
        var isBusy: Bool
        var preservedPageExpiresAt: Date?
        var preservedPageExpiryWorkItem: DispatchWorkItem?

        init(
            webView: WKWebView,
            host: OffscreenWebViewHost,
            lastUsedAt: Date,
            isBusy: Bool,
            preservedPageExpiresAt: Date? = nil)
        {
            self.webView = webView
            self.host = host
            self.lastUsedAt = lastUsedAt
            self.isBusy = isBusy
            self.preservedPageExpiresAt = preservedPageExpiresAt
        }

        func armPreservedPage(until expiry: Date) {
            self.preservedPageExpiresAt = expiry
        }

        func setPreservedPageExpiryWorkItem(_ workItem: DispatchWorkItem?) {
            self.preservedPageExpiryWorkItem?.cancel()
            self.preservedPageExpiryWorkItem = workItem
        }

        func clearPreservedPage() {
            self.preservedPageExpiresAt = nil
            self.preservedPageExpiryWorkItem?.cancel()
            self.preservedPageExpiryWorkItem = nil
        }

        func consumePreservedPageReuseIfAvailable(now: Date) -> Bool {
            guard let preservedPageExpiresAt else { return false }
            self.preservedPageExpiresAt = nil
            self.preservedPageExpiryWorkItem?.cancel()
            self.preservedPageExpiryWorkItem = nil
            return preservedPageExpiresAt > now
        }

        func hasExpiredPreservedPage(now: Date) -> Bool {
            guard let preservedPageExpiresAt else { return false }
            return preservedPageExpiresAt <= now
        }

        func close() {
            self.isBusy = false
            self.clearPreservedPage()
            self.host.close()
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// Explicit invalidation outlives dictionary removal, but only while an acquire is suspended.
    private var acquisitions: [ObjectIdentifier: Acquisition] = [:]
    /// Keep the WebView alive only long enough for immediate retries/menu reopens.
    /// Long-lived hidden ChatGPT tabs still consume noticeable energy on some setups.
    private let idleTimeout: TimeInterval
    private var idlePruneWorkItem: DispatchWorkItem?
    private var idlePruneGeneration = 0
    #if DEBUG
    private(set) var idlePruneDeadlineForTesting: Date?
    var prepareForTesting: ((WKWebView, TimeInterval, Bool) async throws -> Void)?
    var didCreateWebViewForTesting: ((WKWebView, AnyObject) -> Void)?
    #endif
    /// Reuse the validated analytics page only for the immediate next handoff.
    private let preservedPageHandoffTimeout: TimeInterval = 5
    private let reusablePageResetScript = """
    (() => {
      try {
        delete window.__codexbarDidScrollToCredits;
        delete window.__codexbarUsageBreakdownJSON;
        delete window.__codexbarUsageBreakdownDebug;
        return true;
      } catch {
        return false;
      }
    })();
    """
    private let preferredLanguageScript = """
    (() => {
      const define = (target, name, value) => {
        try {
          Object.defineProperty(target, name, {
            get: () => value,
            configurable: true
          });
        } catch {}
      };
      define(Navigator.prototype, 'language', 'en-US');
      define(Navigator.prototype, 'languages', ['en-US', 'en']);
      define(navigator, 'language', 'en-US');
      define(navigator, 'languages', ['en-US', 'en']);
    })();
    """

    init(idleTimeout: TimeInterval = 60) {
        self.idleTimeout = idleTimeout
    }

    nonisolated static func remainingNavigationTimeout(
        until deadline: Date,
        now: Date = Date()) throws -> TimeInterval
    {
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { throw URLError(.timedOut) }
        return remaining
    }

    private func releaseCachedEntry(_ entry: Entry, key: ObjectIdentifier, preserveLoadedPage: Bool) {
        guard self.entries[key] === entry else {
            entry.close()
            return
        }
        entry.isBusy = false
        entry.lastUsedAt = Date()
        if preserveLoadedPage {
            self.updatePreservedPageState(for: entry, preserveLoadedPage: true)
            entry.host.hide()
            self.scheduleNextIdlePrune()
            return
        }
        self.evictEntry(entry)
    }

    private func evictEntry(_ entry: Entry) {
        entry.close()
        if let key = self.entries.first(where: { $0.value === entry })?.key {
            self.entries.removeValue(forKey: key)
        }
        Self.log.debug("OpenAI webview evicted after release")
        self.scheduleNextIdlePrune()
    }

    // MARK: - Testing support

    #if DEBUG
    /// Number of cached WebView entries (for testing).
    var entryCount: Int {
        self.entries.count
    }

    var activeAcquisitionCountForTesting: Int {
        self.acquisitions.count
    }

    static func cleanupRequestCountForTesting(_ host: AnyObject) -> Int? {
        (host as? OffscreenWebViewHost)?.cleanupRequestCountForTesting
    }

    func cachedWebViewForTesting(for websiteDataStore: WKWebsiteDataStore) -> WKWebView? {
        self.entries[ObjectIdentifier(websiteDataStore)]?.webView
    }

    /// Check if a WebView is cached for the given data store (for testing).
    func hasCachedEntry(for websiteDataStore: WKWebsiteDataStore) -> Bool {
        let key = ObjectIdentifier(websiteDataStore)
        return self.entries[key] != nil
    }

    /// Force prune with a custom "now" timestamp (for testing idle timeout).
    func pruneForTesting(now: Date) {
        self.prune(now: now)
    }

    var idleTimeoutForTesting: TimeInterval {
        self.idleTimeout
    }

    var preservedPageHandoffTimeoutForTesting: TimeInterval {
        self.preservedPageHandoffTimeout
    }

    func hasPreservedPageForTesting(for websiteDataStore: WKWebsiteDataStore) -> Bool {
        let key = ObjectIdentifier(websiteDataStore)
        return self.entries[key]?.preservedPageExpiresAt != nil
    }

    func markPreservedPageForTesting(
        websiteDataStore: WKWebsiteDataStore,
        expiresAt: Date = .init().addingTimeInterval(5))
    {
        let key = ObjectIdentifier(websiteDataStore)
        guard let entry = self.entries[key] else { return }
        entry.armPreservedPage(until: expiresAt)
        self.schedulePreservedPageExpiry(for: key, entry: entry, expiresAt: expiresAt)
    }

    func consumePreservedPageForTesting(websiteDataStore: WKWebsiteDataStore, now: Date = Date()) -> Bool {
        let key = ObjectIdentifier(websiteDataStore)
        guard let entry = self.entries[key] else { return false }
        return entry.consumePreservedPageReuseIfAvailable(now: now)
    }

    /// Seed a cached entry without navigating a real page (for test stability).
    @discardableResult
    func cacheEntryForTesting(
        websiteDataStore: WKWebsiteDataStore,
        lastUsedAt: Date = Date(),
        isBusy: Bool = false) -> WKWebView
    {
        let key = ObjectIdentifier(websiteDataStore)
        if let existing = self.entries.removeValue(forKey: key) {
            existing.host.close()
        }

        let (webView, host) = self.makeWebView(websiteDataStore: websiteDataStore)
        let entry = Entry(webView: webView, host: host, lastUsedAt: lastUsedAt, isBusy: isBusy)
        self.entries[key] = entry
        if isBusy {
            host.show()
        } else {
            host.hide()
        }
        return webView
    }

    /// Clear all cached entries (for test isolation).
    func clearAllForTesting() {
        self.evictAll()
    }

    func resetReusablePageStateForTesting(_ webView: WKWebView) async -> Bool {
        await self.resetReusablePageState(webView)
    }
    #endif

    func acquire(
        websiteDataStore: WKWebsiteDataStore,
        usageURL: URL,
        logger: ((String) -> Void)?,
        navigationTimeout: TimeInterval = 15,
        allowTimeoutRetry: Bool = true,
        preserveLoadedPageOnRelease: Bool = false) async throws -> OpenAIDashboardWebViewLease
    {
        let deadline = Date().addingTimeInterval(max(navigationTimeout, 0.01))
        let key = ObjectIdentifier(websiteDataStore)
        let acquisition = Acquisition(key: key)
        let acquisitionID = ObjectIdentifier(acquisition)
        self.acquisitions[acquisitionID] = acquisition
        defer { self.acquisitions.removeValue(forKey: acquisitionID) }

        let log: (String) -> Void = { message in
            logger?("[webview] \(message)")
        }
        self.prune(now: Date())
        let isTemporary = self.entries[key]?.isBusy == true
        if isTemporary { log("Cached WebView busy; using a temporary WebView.") }
        var canRetry = allowTimeoutRetry

        while true {
            try acquisition.checkCancellation()
            let now = Date()
            let remainingTimeout = try Self.remainingNavigationTimeout(until: deadline, now: now)
            let entry: Entry
            let canReuseLoadedPage: Bool
            if !isTemporary, let cached = self.entries[key] {
                entry = cached
                canReuseLoadedPage = entry.consumePreservedPageReuseIfAvailable(now: now)
            } else {
                let (webView, host) = self.makeWebView(websiteDataStore: websiteDataStore)
                entry = Entry(webView: webView, host: host, lastUsedAt: now, isBusy: true)
                canReuseLoadedPage = false
                if !isTemporary { self.entries[key] = entry }
            }
            acquisition.entry = entry
            entry.isBusy = true
            entry.lastUsedAt = now
            entry.host.show()

            do {
                try await self.prepareWebView(
                    entry.webView,
                    usageURL: usageURL,
                    timeout: remainingTimeout,
                    canReuseLoadedPage: canReuseLoadedPage)
                try acquisition.checkCancellation()
                if !isTemporary, self.entries[key] !== entry { throw CancellationError() }
            } catch {
                let stillOwnsEntry = isTemporary || self.entries[key] === entry
                self.evictEntry(entry)
                try acquisition.checkCancellation()
                guard stillOwnsEntry else { throw CancellationError() }
                guard canRetry, Self.isPrepareTimeout(error) else {
                    Self.log.warning("OpenAI webview prepare failed")
                    throw error
                }
                canRetry = false
                log("OpenAI WebView timed out during prepare; retrying once with a fresh WebView.")
                continue
            }

            return self.makeLease(
                entry: entry,
                key: key,
                isTemporary: isTemporary,
                preserveLoadedPageOnRelease: preserveLoadedPageOnRelease,
                log: log)
        }
    }

    private func makeLease(
        entry: Entry,
        key: ObjectIdentifier,
        isTemporary: Bool,
        preserveLoadedPageOnRelease: Bool,
        log: @escaping (String) -> Void) -> OpenAIDashboardWebViewLease
    {
        let releaseState = ReleaseState(preserveLoadedPageOnRelease: preserveLoadedPageOnRelease)
        // The lease owns cleanup even after cache eviction; the entry never retains its lease.
        return OpenAIDashboardWebViewLease(
            webView: entry.webView,
            log: log,
            setPreserveLoadedPageOnRelease: { preserve in
                guard !releaseState.isReleased else { return }
                releaseState.preserveLoadedPageOnRelease = preserve
            },
            release: { [weak self, entry] in
                guard !releaseState.isReleased else { return }
                releaseState.isReleased = true
                if !isTemporary, let self {
                    self.releaseCachedEntry(
                        entry,
                        key: key,
                        preserveLoadedPage: releaseState.preserveLoadedPageOnRelease)
                } else {
                    entry.close()
                }
            })
    }

    private func invalidateAcquisitions(for key: ObjectIdentifier? = nil) {
        for acquisition in self.acquisitions.values where key == nil || acquisition.key == key {
            acquisition.isInvalidated = true
            acquisition.entry?.close()
        }
    }

    func evict(websiteDataStore: WKWebsiteDataStore) {
        let key = ObjectIdentifier(websiteDataStore)
        self.invalidateAcquisitions(for: key)
        guard let entry = self.entries.removeValue(forKey: key) else { return }
        entry.close()
        Self.log.debug("OpenAI webview evicted")
        self.scheduleNextIdlePrune()
    }

    func evictAll() {
        self.invalidateAcquisitions()
        self.cancelIdlePrune()
        let existing = self.entries
        self.entries.removeAll()
        for (_, entry) in existing {
            entry.close()
        }
        if !existing.isEmpty {
            Self.log.debug("OpenAI webview evicted all")
        }
    }

    func evictIdle() {
        let idleEntries = self.entries.filter { _, entry in
            !entry.isBusy
        }
        guard !idleEntries.isEmpty else { return }

        for (key, entry) in idleEntries {
            entry.clearPreservedPage()
            entry.host.close()
            self.entries.removeValue(forKey: key)
        }
        Self.log.debug("OpenAI idle webviews evicted", metadata: ["count": "\(idleEntries.count)"])
        self.scheduleNextIdlePrune()
    }

    /// Schedule against the oldest idle entry so later releases cannot postpone its eviction.
    private func scheduleNextIdlePrune(now: Date = Date()) {
        self.cancelIdlePrune()

        guard let nextExpiry = self.entries.values
            .filter({ !$0.isBusy })
            .map({ $0.lastUsedAt.addingTimeInterval(self.idleTimeout) })
            .min()
        else { return }

        let generation = self.idlePruneGeneration
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.idlePruneGeneration == generation else { return }
                self.idlePruneWorkItem = nil
                #if DEBUG
                self.idlePruneDeadlineForTesting = nil
                #endif
                let pruneTime = Date()
                self.prune(now: pruneTime)
                self.scheduleNextIdlePrune(now: pruneTime)
            }
        }
        self.idlePruneWorkItem = workItem
        #if DEBUG
        self.idlePruneDeadlineForTesting = nextExpiry
        #endif
        let delay = max(0, nextExpiry.timeIntervalSince(now)) + 0.01
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelIdlePrune() {
        self.idlePruneGeneration &+= 1
        self.idlePruneWorkItem?.cancel()
        self.idlePruneWorkItem = nil
        #if DEBUG
        self.idlePruneDeadlineForTesting = nil
        #endif
    }

    private func prune(now: Date) {
        let expiredPreserved = self.entries.values.filter { entry in
            !entry.isBusy && entry.hasExpiredPreservedPage(now: now)
        }
        for entry in expiredPreserved {
            Self.log.debug("OpenAI webview preserved page expired")
            self.evictEntry(entry)
        }

        let expired = self.entries.filter { _, entry in
            !entry.isBusy && now.timeIntervalSince(entry.lastUsedAt) >= self.idleTimeout
        }
        for (_, entry) in expired {
            Self.log.debug("OpenAI webview pruned")
            self.evictEntry(entry)
        }
    }

    private func makeWebView(websiteDataStore: WKWebsiteDataStore) -> (WKWebView, OffscreenWebViewHost) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = websiteDataStore
        let userContentController = WKUserContentController()
        userContentController.addUserScript(WKUserScript(
            source: self.preferredLanguageScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
        userContentController.addUserScript(WKUserScript(
            source: openAISubscriptionCaptureScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
        config.userContentController = userContentController
        if #available(macOS 14.0, *) {
            config.preferences.inactiveSchedulingPolicy = .suspend
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        let host = OffscreenWebViewHost(webView: webView)
        #if DEBUG
        self.didCreateWebViewForTesting?(webView, host)
        #endif
        return (webView, host)
    }

    private func prepareWebView(
        _ webView: WKWebView,
        usageURL: URL,
        timeout: TimeInterval,
        canReuseLoadedPage: Bool) async throws
    {
        #if DEBUG
        if let prepareForTesting {
            try await prepareForTesting(webView, timeout, canReuseLoadedPage)
            return
        }
        if usageURL.absoluteString == "about:blank" {
            _ = webView.loadHTMLString("", baseURL: nil)
            return
        }
        #endif

        if canReuseLoadedPage,
           let currentURL = webView.url?.absoluteString,
           OpenAIDashboardFetcher.isUsageRoute(currentURL)
        {
            if await self.resetReusablePageState(webView) {
                return
            }

            Self.log.debug("OpenAI preserved page reset failed; reloading usage URL")
        }

        try Task.checkCancellation()
        let cancellationState = NavigationCancellationState()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let delegate = NavigationDelegate { result in
                    cont.resume(with: result)
                }
                webView.navigationDelegate = delegate
                webView.codexNavigationDelegate = delegate
                cancellationState.install(webView: webView, delegate: delegate)
                delegate.armTimeout(seconds: timeout)
                _ = webView.load(OpenAIDashboardFetcher.usageURLRequest(url: usageURL))
                if Task.isCancelled {
                    cancellationState.cancel()
                }
            }
        } onCancel: {
            Task { @MainActor in
                cancellationState.cancel()
            }
        }
    }

    private static func isPrepareTimeout(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    private func updatePreservedPageState(for entry: Entry, preserveLoadedPage: Bool) {
        if preserveLoadedPage {
            let expiresAt = Date().addingTimeInterval(self.preservedPageHandoffTimeout)
            entry.armPreservedPage(until: expiresAt)
            if let key = self.entries.first(where: { $0.value === entry })?.key {
                self.schedulePreservedPageExpiry(for: key, entry: entry, expiresAt: expiresAt)
            }
        } else {
            entry.clearPreservedPage()
        }
    }

    private func schedulePreservedPageExpiry(
        for key: ObjectIdentifier,
        entry: Entry,
        expiresAt: Date)
    {
        let delay = max(0, expiresAt.timeIntervalSinceNow)
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.expirePreservedPageIfNeeded(for: key, expectedExpiry: expiresAt)
            }
        }
        entry.setPreservedPageExpiryWorkItem(workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func expirePreservedPageIfNeeded(for key: ObjectIdentifier, expectedExpiry: Date) {
        guard let entry = self.entries[key],
              !entry.isBusy,
              let preservedPageExpiresAt = entry.preservedPageExpiresAt,
              preservedPageExpiresAt == expectedExpiry,
              preservedPageExpiresAt <= Date()
        else {
            return
        }

        Self.log.debug("OpenAI webview preserved page expired")
        self.evictEntry(entry)
    }

    private func resetReusablePageState(_ webView: WKWebView) async -> Bool {
        do {
            let any = try await webView.evaluateJavaScript(self.reusablePageResetScript)
            return (any as? Bool) ?? true
        } catch {
            return false
        }
    }
}

@MainActor
private final class OffscreenWebViewHost {
    private let window: NSWindow
    private weak var webView: WKWebView?
    private var isClosed = false
    #if DEBUG
    private(set) var cleanupRequestCountForTesting = 0
    #endif

    init(webView: WKWebView) {
        // WebKit throttles timers/RAF aggressively when a WKWebView is not considered "visible".
        // The Codex usage page uses streaming SSR + client hydration; if RAF is throttled, the
        // dashboard never becomes part of the visible DOM and `document.body.innerText` stays tiny.
        //
        // Keep a transparent (mouse-ignoring) window technically "on-screen" while scraping, but
        // place it almost entirely off-screen so we never ghost-render dashboard UI over the desktop.
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let frame = OpenAIDashboardFetcher.offscreenHostWindowFrame(for: visibleFrame)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        // Keep it effectively invisible, but non-zero alpha so WebKit treats it as "visible" and doesn't
        // stall hydration (we've observed a head-only HTML shell for minutes at alpha=0).
        window.alphaValue = OpenAIDashboardFetcher.offscreenHostAlphaValue()
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isExcludedFromWindowsMenu = true
        window.contentView = webView

        self.window = window
        self.webView = webView
    }

    func show() {
        OpenAIDashboardWebViewCache.log.debug("OpenAI webview show")
        self.window.alphaValue = OpenAIDashboardFetcher.offscreenHostAlphaValue()
        self.window.orderFrontRegardless()
    }

    func hide() {
        // Set alpha to 0 so WebKit recognizes the page as inactive and applies
        // its scheduling policy (throttle/suspend), reducing CPU when idle.
        OpenAIDashboardWebViewCache.log.debug("OpenAI webview hide")
        self.window.alphaValue = 0.0
        self.window.orderOut(nil)
    }

    func close() {
        guard !self.isClosed else { return }
        self.isClosed = true
        #if DEBUG
        self.cleanupRequestCountForTesting += 1
        #endif
        OpenAIDashboardWebViewCache.log.debug("OpenAI webview close")
        WebKitTeardown.scheduleCleanup(
            owner: self,
            window: self.window,
            webView: self.webView,
            closeWindow: { [window] in
                window.orderOut(nil)
                window.close()
            })
    }
}

#endif
