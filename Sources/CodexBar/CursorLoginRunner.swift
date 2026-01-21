import AppKit
import CodexBarCore
import Foundation
import WebKit

/// Handles Cursor login flow using a WebKit-based browser window.
/// Captures session cookies after successful authentication.
@MainActor
final class CursorLoginRunner: NSObject {
    enum Phase: Sendable {
        case loading
        case waitingLogin
        case success
        case failed(String)
    }

    struct Result: Sendable {
        enum Outcome: Sendable {
            case success
            case cancelled
            case failed(String)
        }

        let outcome: Outcome
        let email: String?
    }

    private let browserDetection: BrowserDetection
    private var webView: WKWebView?
    private var window: NSWindow?
    private var continuation: CheckedContinuation<Result, Never>?
    private var phaseCallback: ((Phase) -> Void)?
    private var hasCompletedLogin = false
    private let logger = CodexBarLog.logger(LogCategories.cursorLogin)

    private static let dashboardURL = URL(string: "https://cursor.com/dashboard")!
    private static let loginURLPattern = "authenticator.cursor.sh"

    init(browserDetection: BrowserDetection) {
        self.browserDetection = browserDetection
        super.init()
    }

    /// Runs the Cursor login flow in a browser window.
    /// Returns the result after the user completes login or cancels.
    func run(onPhaseChange: @escaping @Sendable (Phase) -> Void) async -> Result {
        // Keep this instance alive during the flow.
        WebKitTeardown.retain(self)
        self.phaseCallback = onPhaseChange
        onPhaseChange(.loading)
        self.logger.info("Cursor login started")

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.setupWindow()
        }
    }

    private func setupWindow() {
        // Use a non-persistent store for the login flow; cookies are persisted explicitly.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: config)
        webView.navigationDelegate = self
        self.webView = webView

        // Create window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Cursor Login"
        window.contentView = webView
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.logger.info("Cursor login window opened")

        // Navigate to dashboard (will redirect to login if not authenticated)
        let request = URLRequest(url: Self.dashboardURL)
        webView.load(request)
    }

    private func complete(with result: Result) {
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        self.logger.info("Cursor login completed", metadata: ["outcome": "\(result.outcome)"])
        self.scheduleCleanup()
        continuation.resume(returning: result)
    }

    private func scheduleCleanup() {
        self.logger.info("Cursor login window closing")
        WebKitTeardown.scheduleCleanup(owner: self, window: self.window, webView: self.webView)
    }

    private func captureSessionCookies() async {
        guard let webView = self.webView else { return }

        let dataStore = webView.configuration.websiteDataStore
        let cookies = await dataStore.httpCookieStore.allCookies()

        // Filter for cursor.com cookies
        let cursorCookies = cookies.filter { cookie in
            cookie.domain.contains("cursor.com") || cookie.domain.contains("cursor.sh")
        }

        guard !cursorCookies.isEmpty else {
            self.phaseCallback?(.failed("No session cookies found"))
            self.logger.warning("Cursor login failed: no session cookies found")
            self.complete(with: Result(outcome: .failed("No session cookies found"), email: nil))
            return
        }

        // Save cookies to the session store
        await CursorSessionStore.shared.setCookies(cursorCookies)
        self.logger.info("Cursor session cookies captured", metadata: ["count": "\(cursorCookies.count)"])

        // Try to get user email
        let email = await self.fetchUserEmail()

        self.hasCompletedLogin = true
        self.phaseCallback?(.success)
        self.complete(with: Result(outcome: .success, email: email))
    }

    private func fetchUserEmail() async -> String? {
        do {
            let probe = CursorStatusProbe(browserDetection: self.browserDetection)
            let snapshot = try await probe.fetch()
            return snapshot.accountEmail
        } catch {
            return nil
        }
    }
}

// MARK: - WKNavigationDelegate

extension CursorLoginRunner: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard let url = webView.url else { return }

            let urlString = url.absoluteString

            // Check if on login page
            if urlString.contains(Self.loginURLPattern) {
                self.phaseCallback?(.waitingLogin)
                return
            }

            // Check if on dashboard (login successful)
            if urlString.contains("cursor.com/dashboard"), !self.hasCompletedLogin {
                await self.captureSessionCookies()
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!)
    {
        Task { @MainActor in
            guard let url = webView.url else { return }
            let urlString = url.absoluteString

            // Detect redirect to dashboard after login
            if urlString.contains("cursor.com/dashboard"), !self.hasCompletedLogin {
                // Wait a moment for cookies to be set, then capture
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self.captureSessionCookies()
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error)
    {
        Task { @MainActor in
            self.phaseCallback?(.failed(error.localizedDescription))
            self.logger.error("Cursor login navigation failed", metadata: ["error": error.localizedDescription])
            self.complete(with: Result(outcome: .failed(error.localizedDescription), email: nil))
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error)
    {
        Task { @MainActor in
            // Ignore cancelled navigations (common during redirects)
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                return
            }
            self.phaseCallback?(.failed(error.localizedDescription))
            self.logger.error("Cursor login navigation failed", metadata: ["error": error.localizedDescription])
            self.complete(with: Result(outcome: .failed(error.localizedDescription), email: nil))
        }
    }
}

// MARK: - NSWindowDelegate

extension CursorLoginRunner: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            if !self.hasCompletedLogin {
                self.logger.info("Cursor login cancelled")
                self.complete(with: Result(outcome: .cancelled, email: nil))
            }
        }
    }
}
