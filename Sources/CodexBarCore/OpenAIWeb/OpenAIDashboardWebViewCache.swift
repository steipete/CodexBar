#if os(macOS)
import AppKit
import Foundation
import WebKit

struct OpenAIDashboardWebViewLease {
    let webView: WKWebView
    let log: (String) -> Void
    let release: () -> Void
}
#endif

@MainActor
final class OpenAIDashboardWebViewCache {
    static let shared = OpenAIDashboardWebViewCache()

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
                entry.host.hide()
                throw error
            }

            return OpenAIDashboardWebViewLease(
                webView: entry.webView,
                log: log,
                release: { [weak self, weak entry] in
                    guard let self, let entry else { return }
                    entry.isBusy = false
                    entry.lastUsedAt = Date()
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
            throw error
        }

        return OpenAIDashboardWebViewLease(
            webView: webView,
            log: log,
            release: { [weak self, weak entry] in
                guard let self, let entry else { return }
                entry.isBusy = false
                entry.lastUsedAt = Date()
                entry.host.hide()
                self.prune(now: Date())
            })
    }

    func evict(websiteDataStore: WKWebsiteDataStore) {
        let key = ObjectIdentifier(websiteDataStore)
        guard let entry = self.entries.removeValue(forKey: key) else { return }
        entry.host.close()
    }

    private func prune(now: Date) {
        let expired = self.entries.filter { _, entry in
            !entry.isBusy && now.timeIntervalSince(entry.lastUsedAt) > self.idleTimeout
        }
        for (key, entry) in expired {
            entry.host.close()
            self.entries.removeValue(forKey: key)
        }
    }

    private func makeWebView(websiteDataStore: WKWebsiteDataStore) -> (WKWebView, OffscreenWebViewHost) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = websiteDataStore

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
    }

    func show() {
        self.window.orderFrontRegardless()
    }

    func hide() {
        self.window.orderOut(nil)
    }

    func close() {
        self.window.orderOut(nil)
        self.window.close()
    }
}
