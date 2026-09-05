#if os(macOS)
import AppKit
import Foundation
import WebKit

@MainActor
enum MuseWebViewUsageFetcher {
    private static let pollInterval = Duration.milliseconds(350)

    static func fetchUsage(
        session: MuseCookieImporter.SessionInfo,
        timeout: TimeInterval) async throws -> UsageSnapshot
    {
        guard let dashboardURL = session.dashboardURL else {
            throw MuseUsageError.apiError("Missing the scoped dev.meta.ai usage URL")
        }

        _ = NSApplication.shared
        let dataStore = WKWebsiteDataStore.nonPersistent()
        for cookie in session.cookies {
            await withCheckedContinuation { continuation in
                dataStore.httpCookieStore.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: configuration)
        webView.customUserAgent = session.userAgent
        let host = MuseOffscreenWebViewHost(webView: webView)
        host.show()
        defer { host.close() }

        try await self.navigate(webView: webView, to: dashboardURL, timeout: timeout)
        let deadline = Date().addingTimeInterval(timeout)
        var lastBodyText = ""
        while Date() < deadline {
            try Task.checkCancellation()
            if let bodyText = try await webView.evaluateJavaScript(
                "document.body ? document.body.innerText : ''") as? String
            {
                lastBodyText = bodyText
                if let snapshot = MuseWebUsageFetcher.parseRenderedDashboardText(bodyText) {
                    return snapshot
                }
                if self.isLoginPage(bodyText) {
                    throw MuseUsageError.apiError("WebKit rejected the imported dev.meta.ai browser session")
                }
            }
            try await Task.sleep(for: self.pollInterval)
        }

        if self.isLoginPage(lastBodyText) {
            throw MuseUsageError.apiError("WebKit rejected the imported dev.meta.ai browser session")
        }
        throw MuseUsageError.parseFailed("Timed out waiting for the Muse usage dashboard to render")
    }

    private static func navigate(webView: WKWebView, to url: URL, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = NavigationDelegate { result in
                continuation.resume(with: result)
            }
            webView.navigationDelegate = delegate
            webView.codexNavigationDelegate = delegate
            delegate.armTimeout(seconds: timeout)

            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.setValue(
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                forHTTPHeaderField: "Accept")
            _ = webView.load(request)
        }
    }

    private static func isLoginPage(_ bodyText: String) -> Bool {
        let text = bodyText.lowercased()
        return !text.contains("spend (usd)") &&
            (text.contains("log in to continue") || text.contains("log into facebook"))
    }
}

@MainActor
private final class MuseOffscreenWebViewHost {
    private let window: NSWindow
    private weak var webView: WKWebView?
    private var isClosed = false

    init(webView: WKWebView) {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1100, height: 760)
        let frame = NSRect(
            x: visibleFrame.minX - 1099,
            y: visibleFrame.minY - 759,
            width: 1100,
            height: 760)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.alphaValue = 0.01
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
        self.window.orderFrontRegardless()
    }

    func close() {
        guard !self.isClosed else { return }
        self.isClosed = true
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
