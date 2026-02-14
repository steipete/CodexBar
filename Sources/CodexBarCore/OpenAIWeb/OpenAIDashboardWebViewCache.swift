#if os(macOS)
import AppKit
import Foundation
import WebKit

struct OpenAIDashboardWebViewLease {
    let webView: WKWebView
    let log: (String) -> Void
    let release: () -> Void
}

@MainActor
final class OpenAIDashboardWebViewCache {
    static let shared = OpenAIDashboardWebViewCache()
    fileprivate static let log = CodexBarLog.logger(LogCategories.openAIWebview)

    private final class Entry {
        let webView: WKWebView
        let host: OffscreenWebViewHost
        var lastUsedAt: Date
        var isBusy: Bool

        init(webView: WKWebView, host: OffscreenWebViewHost, lastUsedAt: Date, isBusy: Bool) {
            self.webView = webView
            self.host = host
            self.lastUsedAt = lastUsedAt
            self.isBusy = isBusy
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private let idleTimeout: TimeInterval = 10 * 60

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

    /// Clear all cached entries (for test isolation).
    func clearAllForTesting() {
        for (_, entry) in self.entries {
            entry.host.close()
        }
        self.entries.removeAll()
    }
    #endif

    func acquire(
        websiteDataStore: WKWebsiteDataStore,
        usageURL: URL,
        logger: ((String) -> Void)?) async throws -> OpenAIDashboardWebViewLease
    {
        let now = Date()
        self.prune(now: now)

        let log: (String) -> Void = { message in
            logger?("[webview] \(message)")
        }
        let key = ObjectIdentifier(websiteDataStore)

        if let entry = self.entries[key] {
            if entry.isBusy {
                log("Cached WebView busy; using a temporary WebView.")
                let (webView, host) = self.makeWebView(websiteDataStore: websiteDataStore)
                host.show()
                do {
                    try await self.prepareWebView(webView, usageURL: usageURL)
                } catch {
                    host.close()
                    throw error
                }
                return OpenAIDashboardWebViewLease(
                    webView: webView,
                    log: log,
                    release: { host.close() })
            }

            entry.isBusy = true
            entry.lastUsedAt = now
            entry.host.show()
            do {
                try await self.prepareWebView(entry.webView, usageURL: usageURL)
            } catch {
                entry.isBusy = false
                entry.lastUsedAt = Date()
                entry.host.close()
                self.entries.removeValue(forKey: key)
                Self.log.warning("OpenAI webview prepare failed")
                throw error
            }

            return OpenAIDashboardWebViewLease(
                webView: entry.webView,
                log: log,
                release: { [weak self, weak entry] in
                    guard let self, let entry else { return }
                    entry.isBusy = false
                    entry.lastUsedAt = Date()
                    // Hide instead of close - keep WebView cached for reuse.
                    // This avoids re-downloading the ChatGPT SPA bundle on every refresh,
                    // saving significant network bandwidth. See GitHub issues #269, #251.
                    entry.host.hide()
                    self.prune(now: Date())
                })
        }

        let (webView, host) = self.makeWebView(websiteDataStore: websiteDataStore)
        let entry = Entry(webView: webView, host: host, lastUsedAt: now, isBusy: true)
        self.entries[key] = entry
        host.show()

        do {
            try await self.prepareWebView(webView, usageURL: usageURL)
        } catch {
            self.entries.removeValue(forKey: key)
            host.close()
            Self.log.warning("OpenAI webview prepare failed")
            throw error
        }

        return OpenAIDashboardWebViewLease(
            webView: webView,
            log: log,
            release: { [weak self, weak entry] in
                guard let self, let entry else { return }
                entry.isBusy = false
                entry.lastUsedAt = Date()
                // Hide instead of close - keep WebView cached for reuse.
                // This avoids re-downloading the ChatGPT SPA bundle on every refresh,
                // saving significant network bandwidth. See GitHub issues #269, #251.
                entry.host.hide()
                self.prune(now: Date())
            })
    }

    func evict(websiteDataStore: WKWebsiteDataStore) {
        let key = ObjectIdentifier(websiteDataStore)
        guard let entry = self.entries.removeValue(forKey: key) else { return }
        Self.log.debug("OpenAI webview evicted")
        entry.host.close()
    }

    private func prune(now: Date) {
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
        if #available(macOS 14.0, *) {
            config.preferences.inactiveSchedulingPolicy = .suspend
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        let host = OffscreenWebViewHost(webView: webView)
        return (webView, host)
    }

    private func prepareWebView(_ webView: WKWebView, usageURL: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let delegate = NavigationDelegate { result in
                cont.resume(with: result)
            }
            webView.navigationDelegate = delegate
            webView.codexNavigationDelegate = delegate
            _ = webView.load(URLRequest(url: usageURL))
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
