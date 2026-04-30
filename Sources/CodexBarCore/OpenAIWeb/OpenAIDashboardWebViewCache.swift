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
    fileprivate static let log = CodexBarLog.logger(LogCategories.openAIWebview)

    private final class ReleaseState {
        var preserveLoadedPageOnRelease: Bool

        init(preserveLoadedPageOnRelease: Bool) {
            self.preserveLoadedPageOnRelease = preserveLoadedPageOnRelease
        }
    }

    private struct AcquireOptions {
        let allowTimeoutRetry: Bool
        let preserveLoadedPageOnRelease: Bool
    }

    private final class Entry {
        let webView: WKWebView
        let host: OffscreenWebViewHost
        var lastUsedAt: Date
        var isBusy: Bool
        var preservedPageExpiresAt: Date?
        var preservedPageExpiryTask: Task<Void, Never>?

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

        func setPreservedPageExpiryTask(_ task: Task<Void, Never>?) {
            self.preservedPageExpiryTask?.cancel()
            self.preservedPageExpiryTask = task
        }

        func clearPreservedPage() {
            self.preservedPageExpiresAt = nil
            self.preservedPageExpiryTask?.cancel()
            self.preservedPageExpiryTask = nil
        }

        func consumePreservedPageReuseIfAvailable(now: Date) -> Bool {
            guard let preservedPageExpiresAt else { return false }
            self.preservedPageExpiresAt = nil
            self.preservedPageExpiryTask?.cancel()
            self.preservedPageExpiryTask = nil
            return preservedPageExpiresAt > now
        }

        func hasExpiredPreservedPage(now: Date) -> Bool {
            guard let preservedPageExpiresAt else { return false }
            return preservedPageExpiresAt <= now
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// Keep the WebView alive only long enough for immediate retries/menu reopens.
    /// Long-lived hidden ChatGPT tabs still consume noticeable energy on some setups.
    private let idleTimeout: TimeInterval = 60
    /// Reuse the validated analytics page only for the immediate next handoff.
    private let preservedPageHandoffTimeout: TimeInterval = 5
    private let blankURL = URL(string: "about:blank")!
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

    private func releaseCachedEntry(_ entry: Entry, preserveLoadedPage: Bool) {
        entry.isBusy = false
        entry.lastUsedAt = Date()
        self.updatePreservedPageState(for: entry, preserveLoadedPage: preserveLoadedPage)
        self.prepareCachedWebViewForIdle(
            entry.webView,
            host: entry.host,
            preserveLoadedPage: preserveLoadedPage)
        self.prune(now: Date())
    }

    private func releaseNewEntry(_ entry: Entry, webView: WKWebView, preserveLoadedPage: Bool) {
        entry.isBusy = false
        entry.lastUsedAt = Date()
        self.updatePreservedPageState(for: entry, preserveLoadedPage: preserveLoadedPage)
        self.prepareCachedWebViewForIdle(
            webView,
            host: entry.host,
            preserveLoadedPage: preserveLoadedPage)
        self.prune(now: Date())
    }

    // MARK: - Testing support

    #if DEBUG
    /// Number of cached WebView entries (for testing).
    var entryCount: Int {
        self.entries.count
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
        for (_, entry) in self.entries {
            entry.clearPreservedPage()
            entry.host.close()
        }
        self.entries.removeAll()
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
        preserveLoadedPageOnRelease: Bool = false) async throws -> OpenAIDashboardWebViewLease
    {
        let deadline = Date().addingTimeInterval(max(navigationTimeout, 1))
        return try await self.acquire(
            websiteDataStore: websiteDataStore,
            usageURL: usageURL,
            logger: logger,
            deadline: deadline,
            options: .init(
                allowTimeoutRetry: true,
                preserveLoadedPageOnRelease: preserveLoadedPageOnRelease))
    }

    private func acquire(
        websiteDataStore: WKWebsiteDataStore,
        usageURL: URL,
        logger: ((String) -> Void)?,
        deadline: Date,
        options: AcquireOptions) async throws -> OpenAIDashboardWebViewLease
    {
        let now = Date()
        self.prune(now: now)

        let log: (String) -> Void = { message in
            logger?("[webview] \(message)")
        }
        let key = ObjectIdentifier(websiteDataStore)
        let remainingTimeout = max(0.5, deadline.timeIntervalSince(now))

        if let entry = self.entries[key] {
            if entry.isBusy {
                log("Cached WebView busy; using a temporary WebView.")
                let (webView, host) = self.makeWebView(websiteDataStore: websiteDataStore)
                host.show()
                do {
                    try await self.prepareWebView(
                        webView,
                        usageURL: usageURL,
                        timeout: remainingTimeout,
                        canReuseLoadedPage: false)
                } catch {
                    if options.allowTimeoutRetry, Self.isPrepareTimeout(error) {
                        host.close()
                        log("Temporary OpenAI WebView timed out; retrying with a fresh WebView.")
                        return try await self.acquireTemporaryWebView(
                            websiteDataStore: websiteDataStore,
                            usageURL: usageURL,
                            log: log,
                            deadline: deadline)
                    }
                    host.close()
                    throw error
                }
                return OpenAIDashboardWebViewLease(
                    webView: webView,
                    log: log,
                    setPreserveLoadedPageOnRelease: { _ in },
                    release: { host.close() })
            }

            entry.isBusy = true
            entry.lastUsedAt = now
            let canReuseLoadedPage = entry.consumePreservedPageReuseIfAvailable(now: now)
            let releaseState = ReleaseState(preserveLoadedPageOnRelease: options.preserveLoadedPageOnRelease)
            entry.host.show()
            do {
                try await self.prepareWebView(
                    entry.webView,
                    usageURL: usageURL,
                    timeout: remainingTimeout,
                    canReuseLoadedPage: canReuseLoadedPage)
            } catch {
                if options.allowTimeoutRetry, Self.isPrepareTimeout(error) {
                    entry.isBusy = false
                    entry.lastUsedAt = Date()
                    entry.clearPreservedPage()
                    entry.host.close()
                    self.entries.removeValue(forKey: key)
                    log("Cached OpenAI WebView timed out; recreating it.")
                    return try await self.acquire(
                        websiteDataStore: websiteDataStore,
                        usageURL: usageURL,
                        logger: logger,
                        deadline: deadline,
                        options: .init(
                            allowTimeoutRetry: false,
                            preserveLoadedPageOnRelease: options.preserveLoadedPageOnRelease))
                }
                entry.isBusy = false
                entry.lastUsedAt = Date()
                entry.clearPreservedPage()
                entry.host.close()
                self.entries.removeValue(forKey: key)
                Self.log.warning("OpenAI webview prepare failed")
                throw error
            }

            return OpenAIDashboardWebViewLease(
                webView: entry.webView,
                log: log,
                setPreserveLoadedPageOnRelease: { preserveLoadedPageOnRelease in
                    releaseState.preserveLoadedPageOnRelease = preserveLoadedPageOnRelease
                },
                release: { [weak self, weak entry] in
                    guard let self, let entry else { return }
                    self.releaseCachedEntry(
                        entry,
                        preserveLoadedPage: releaseState.preserveLoadedPageOnRelease)
                })
        }

        let (webView, host) = self.makeWebView(websiteDataStore: websiteDataStore)
        let entry = Entry(webView: webView, host: host, lastUsedAt: now, isBusy: true)
        self.entries[key] = entry
        host.show()
        let releaseState = ReleaseState(preserveLoadedPageOnRelease: options.preserveLoadedPageOnRelease)

        do {
            try await self.prepareWebView(
                webView,
                usageURL: usageURL,
                timeout: remainingTimeout,
                canReuseLoadedPage: false)
        } catch {
            if options.allowTimeoutRetry, Self.isPrepareTimeout(error) {
                self.entries.removeValue(forKey: key)
                host.close()
                log("OpenAI WebView timed out during prepare; retrying once.")
                return try await self.acquire(
                    websiteDataStore: websiteDataStore,
                    usageURL: usageURL,
                    logger: logger,
                    deadline: deadline,
                    options: .init(
                        allowTimeoutRetry: false,
                        preserveLoadedPageOnRelease: options.preserveLoadedPageOnRelease))
            }
            self.entries.removeValue(forKey: key)
            host.close()
            Self.log.warning("OpenAI webview prepare failed")
            throw error
        }

        return OpenAIDashboardWebViewLease(
            webView: webView,
            log: log,
            setPreserveLoadedPageOnRelease: { preserveLoadedPageOnRelease in
                releaseState.preserveLoadedPageOnRelease = preserveLoadedPageOnRelease
            },
            release: { [weak self, weak entry] in
                guard let self, let entry else { return }
                self.releaseNewEntry(
                    entry,
                    webView: webView,
                    preserveLoadedPage: releaseState.preserveLoadedPageOnRelease)
            })
    }

    func evict(websiteDataStore: WKWebsiteDataStore) {
        let key = ObjectIdentifier(websiteDataStore)
        guard let entry = self.entries.removeValue(forKey: key) else { return }
        entry.clearPreservedPage()
        Self.log.debug("OpenAI webview evicted")
        entry.host.close()
    }

    func evictAll() {
        let existing = self.entries
        self.entries.removeAll()
        for (_, entry) in existing {
            entry.clearPreservedPage()
            entry.host.close()
        }
        if !existing.isEmpty {
            Self.log.debug("OpenAI webview evicted all")
        }
    }

    private func prepareCachedWebViewForIdle(
        _ webView: WKWebView,
        host: OffscreenWebViewHost,
        preserveLoadedPage: Bool)
    {
        webView.navigationDelegate = nil
        webView.codexNavigationDelegate = nil
        if preserveLoadedPage {
            host.hide()
            return
        }

        // Detach the heavyweight ChatGPT SPA as soon as a scrape completes. Keeping the WebView object around
        // still helps with immediate reuse, but letting chatgpt.com remain the active document is too expensive.
        webView.stopLoading()
        _ = webView.load(URLRequest(url: self.blankURL))
        host.hide()
    }

    private func prune(now: Date) {
        for entry in self.entries.values where !entry.isBusy && entry.hasExpiredPreservedPage(now: now) {
            entry.clearPreservedPage()
            self.prepareCachedWebViewForIdle(
                entry.webView,
                host: entry.host,
                preserveLoadedPage: false)
            Self.log.debug("OpenAI webview preserved page expired")
        }

        let expired = self.entries.filter { _, entry in
            !entry.isBusy && now.timeIntervalSince(entry.lastUsedAt) > self.idleTimeout
        }
        for (key, entry) in expired {
            entry.host.close()
            self.entries.removeValue(forKey: key)
            Self.log.debug("OpenAI webview pruned")
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
        config.userContentController = userContentController
        if #available(macOS 14.0, *) {
            config.preferences.inactiveSchedulingPolicy = .suspend
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        let host = OffscreenWebViewHost(webView: webView)
        return (webView, host)
    }

    private func prepareWebView(
        _ webView: WKWebView,
        usageURL: URL,
        timeout: TimeInterval,
        canReuseLoadedPage: Bool) async throws
    {
        #if DEBUG
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

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let delegate = NavigationDelegate { result in
                cont.resume(with: result)
            }
            webView.navigationDelegate = delegate
            webView.codexNavigationDelegate = delegate
            delegate.armTimeout(seconds: timeout)
            _ = webView.load(OpenAIDashboardFetcher.usageURLRequest(url: usageURL))
        }
    }

    private func acquireTemporaryWebView(
        websiteDataStore: WKWebsiteDataStore,
        usageURL: URL,
        log: @escaping (String) -> Void,
        deadline: Date) async throws -> OpenAIDashboardWebViewLease
    {
        let remainingTimeout = max(0.5, deadline.timeIntervalSinceNow)
        let (webView, host) = self.makeWebView(websiteDataStore: websiteDataStore)
        host.show()
        do {
            try await self.prepareWebView(
                webView,
                usageURL: usageURL,
                timeout: remainingTimeout,
                canReuseLoadedPage: false)
        } catch {
            host.close()
            throw error
        }
        return OpenAIDashboardWebViewLease(
            webView: webView,
            log: log,
            setPreserveLoadedPageOnRelease: { _ in },
            release: { host.close() })
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
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.expirePreservedPageIfNeeded(for: key, expectedExpiry: expiresAt)
        }
        entry.setPreservedPageExpiryTask(task)
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

        entry.clearPreservedPage()
        self.prepareCachedWebViewForIdle(
            entry.webView,
            host: entry.host,
            preserveLoadedPage: false)
        Self.log.debug("OpenAI webview preserved page expired")
        self.prune(now: Date())
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
