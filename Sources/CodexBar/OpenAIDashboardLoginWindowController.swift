import AppKit
import CodexBarCore
import WebKit

/// Shows a WKWebView window where the user can sign in to chatgpt.com for a specific account.
/// The session cookies are stored in a per-account `WKWebsiteDataStore` so dashboard scraping
/// works independently for each OAuth account without needing browser cookie import.
@MainActor
final class OpenAIDashboardLoginWindowController: NSWindowController, WKNavigationDelegate {
    private static let defaultSize = NSSize(width: 520, height: 700)
    private static let loginURL = URL(string: "https://chatgpt.com/codex/settings/usage")!

    /// Retains active login windows so they aren't deallocated while open.
    private static var activeControllers: [OpenAIDashboardLoginWindowController] = []

    private let logger = CodexBarLog.logger(LogCategories.openAIWebview)
    private var webView: WKWebView?
    private var accountEmail: String?
    private var onComplete: ((Bool) -> Void)?
    private var loginDetected = false

    /// JS snippet that checks if the page shows a logged-in dashboard (not a login/auth page).
    private static let loginCheckScript = """
    (() => {
      const href = location.href || '';
      const body = (document.body && document.body.innerText) || '';
      const isLogin = href.includes('auth.openai.com') ||
                      href.includes('/login') ||
                      body.includes('Welcome back') ||
                      body.includes('Log in') ||
                      body.includes('Sign up');
      const isDashboard = href.includes('/codex/settings/usage') &&
                          !isLogin &&
                          body.length > 200;
      return { href, isLogin, isDashboard, bodyLength: body.length };
    })();
    """

    init(accountEmail: String?, onComplete: ((Bool) -> Void)? = nil) {
        self.accountEmail = Self.normalizeEmail(accountEmail)
        self.onComplete = onComplete
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        Self.activeControllers.append(self)
        if self.window == nil {
            self.buildWindow()
        }
        self.loginDetected = false
        self.load()
        self.window?.center()
        self.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: self.accountEmail)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: .zero)
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let emailLabel = self.accountEmail ?? "account"
        let window = NSWindow(
            contentRect: Self.defaultFrame(),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Sign in to ChatGPT — \(emailLabel)"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = container
        window.center()
        window.delegate = self

        self.window = window
        self.webView = webView
    }

    private func load() {
        guard let webView else { return }
        webView.load(URLRequest(url: Self.loginURL))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.checkLoginStatus(webView: webView)
    }

    private func checkLoginStatus(webView: WKWebView) {
        guard !self.loginDetected else { return }

        webView.evaluateJavaScript(Self.loginCheckScript) { [weak self] result, _ in
            guard let self, let dict = result as? [String: Any] else { return }
            let isDashboard = (dict["isDashboard"] as? Bool) ?? false
            let href = (dict["href"] as? String) ?? ""

            if isDashboard {
                self.logger.info("Dashboard login detected for \(self.accountEmail ?? "account")")
                self.loginDetected = true

                // Brief delay to let cookies finalize, then close.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.onComplete?(true)
                    self.close()
                }
                return
            }

            // If we're on chatgpt.com (not auth.openai.com), keep polling for login completion.
            if href.contains("chatgpt.com"), !href.contains("auth.openai.com") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, let webView = self.webView else { return }
                    self.checkLoginStatus(webView: webView)
                }
            }
        }
    }

    private static func normalizeEmail(_ email: String?) -> String? {
        guard let raw = email?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw.lowercased()
    }

    private static func defaultFrame() -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
        let width = min(Self.defaultSize.width, visible.width * 0.8)
        let height = min(Self.defaultSize.height, visible.height * 0.85)
        let origin = NSPoint(x: visible.midX - width / 2, y: visible.midY - height / 2)
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }
}

// MARK: - NSWindowDelegate

extension OpenAIDashboardLoginWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = self.window else { return }
        let webView = self.webView
        let didLogin = self.loginDetected
        self.webView = nil
        self.window = nil
        self.logger.info("Dashboard login window closing (logged_in=\(didLogin))")
        if !didLogin {
            self.onComplete?(false)
        }
        Self.activeControllers.removeAll { $0 === self }
        WebKitTeardown.scheduleCleanup(owner: window, window: window, webView: webView)
    }
}
