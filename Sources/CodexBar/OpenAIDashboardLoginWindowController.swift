import AppKit
import CodexBarCore
import WebKit

/// NSWindow subclass that always accepts key status so the WKWebView inside can receive keyboard input.
private class WebViewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Shows a WKWebView window where the user can sign in to chatgpt.com.
///
/// Supports two modes:
/// - **Dashboard-only** (`init(accountEmail:onComplete:)`): Signs in for dashboard cookie scraping.
/// - **Unified add-account** (`init(onAccountCreated:)`): Single sign-in that creates a CODEX_HOME
///   with `auth.json` (for API usage) AND stores dashboard cookies (for web extras) in one flow.
@MainActor
final class OpenAIDashboardLoginWindowController: NSWindowController, WKNavigationDelegate {
    private static let defaultSize = NSSize(width: 520, height: 700)
    private static let loginURL = URL(string: "https://chatgpt.com/codex/settings/usage")!

    /// Retains active login windows so they aren't deallocated while open.
    private static var activeControllers: [OpenAIDashboardLoginWindowController] = []

    private let logger = CodexBarLog.logger(LogCategories.openAIWebview)
    private var webView: WKWebView?
    private var accountEmail: String?
    /// Display name for the window title (e.g. resolved email). Falls back to accountEmail.
    private var displayName: String?
    private var loginDetected = false

    // Dashboard-only mode callback.
    private var onComplete: ((Bool) -> Void)?

    /// When true, the window auto-closes after login is detected. When false (view-only mode),
    /// the window stays open for the user to browse the dashboard.
    private var autoCloseOnLogin: Bool = true

    // Unified add-account mode callbacks.
    private var onAccountCreated: ((_ email: String, _ codexHome: String) -> Void)?
    private var onDismissedWithoutLogin: (() -> Void)?
    private var isUnifiedMode: Bool { self.onAccountCreated != nil }

    /// JS that fetches the session endpoint to extract accessToken + user info.
    private static let sessionExtractScript = """
    (async () => {
      try {
        const resp = await fetch('/api/auth/session', { credentials: 'include' });
        if (!resp.ok) return { error: 'status ' + resp.status };
        const json = await resp.json();
        return {
          accessToken: json.accessToken || null,
          email: (json.user && json.user.email) || null,
          name: (json.user && json.user.name) || null,
          accountId: (json.user && json.user.id) || null,
        };
      } catch (e) {
        return { error: String(e) };
      }
    })();
    """

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
      const isDashboard = !isLogin && body.length > 200 &&
                          (href.includes('chatgpt.com') && !href.includes('auth'));
      return { href, isLogin, isDashboard, bodyLength: body.length };
    })();
    """

    /// Dashboard-only mode: sign in for an existing account's web extras.
    /// - Parameter accountEmail: Unique key for cookie store isolation (CODEX_HOME path or email).
    /// - Parameter displayName: Human-readable label for the window title. Falls back to accountEmail.
    /// - Parameter viewOnly: When true, skips login detection polling and keeps the window open for browsing.
    init(accountEmail: String?, displayName: String? = nil, viewOnly: Bool = false, onComplete: ((Bool) -> Void)? = nil) {
        self.accountEmail = Self.normalizeEmail(accountEmail)
        self.displayName = displayName
        self.autoCloseOnLogin = !viewOnly
        self.onComplete = onComplete
        super.init(window: nil)
    }

    /// Unified add-account mode: single sign-in creates both CODEX_HOME credentials + dashboard cookies.
    init(
        onAccountCreated: @escaping (_ email: String, _ codexHome: String) -> Void,
        onDismissed: (() -> Void)? = nil)
    {
        self.onAccountCreated = onAccountCreated
        self.onDismissedWithoutLogin = onDismissed
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Saved activation policy to restore when the window closes.
    private var previousActivationPolicy: NSApplication.ActivationPolicy?

    func show() {
        Self.activeControllers.append(self)
        if self.window == nil {
            self.buildWindow()
        }
        self.loginDetected = false
        self.load()
        self.window?.center()

        // Menu bar apps run as .accessory which prevents WKWebView from receiving
        // keyboard input. Temporarily switch to .regular so the window gets full
        // key event handling, then restore when the window closes.
        self.previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)

        self.showWindow(nil)
        self.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let webView = self.webView {
            self.window?.makeFirstResponder(webView)
        }
    }

    private func buildWindow() {
        let config = WKWebViewConfiguration()
        // For unified mode, we don't know the email yet — use a temporary data store.
        // It will be migrated after we learn the email from the session.
        if self.isUnifiedMode {
            config.websiteDataStore = .nonPersistent()
        } else {
            config.websiteDataStore = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: self.accountEmail)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        let titleLabel = self.displayName ?? self.accountEmail ?? "new account"
        let window = WebViewWindow(
            contentRect: Self.defaultFrame(),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = self.autoCloseOnLogin
            ? "Sign in to ChatGPT — \(titleLabel)"
            : "Dashboard — \(titleLabel)"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = webView
        window.initialFirstResponder = webView
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
        self.window?.makeFirstResponder(webView)
        self.checkLoginStatus(webView: webView)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let webView = self.webView {
            self.window?.makeFirstResponder(webView)
        }
    }

    // MARK: - Login detection

    private func checkLoginStatus(webView: WKWebView) {
        guard !self.loginDetected, self.autoCloseOnLogin else { return }

        webView.evaluateJavaScript(Self.loginCheckScript) { [weak self] result, _ in
            guard let self, let dict = result as? [String: Any] else { return }
            let isDashboard = (dict["isDashboard"] as? Bool) ?? false

            if isDashboard {
                self.logger.info("Dashboard login detected for \(self.accountEmail ?? "new account")")
                self.loginDetected = true

                if self.isUnifiedMode {
                    self.extractSessionAndCreateAccount(webView: webView)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.onComplete?(true)
                        self.close()
                    }
                }
                return
            }

            // Keep polling regardless of current URL.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, let webView = self.webView else { return }
                self.checkLoginStatus(webView: webView)
            }
        }
    }

    // MARK: - Unified mode: extract session and create account

    private func extractSessionAndCreateAccount(webView: WKWebView) {
        self.window?.title = "Extracting account credentials…"

        webView.evaluateJavaScript(Self.sessionExtractScript) { [weak self] result, error in
            guard let self else { return }

            guard let dict = result as? [String: Any],
                  let accessToken = dict["accessToken"] as? String, !accessToken.isEmpty
            else {
                let errorMsg = (result as? [String: Any])?["error"] as? String ?? error?.localizedDescription ?? "unknown"
                self.logger.error("Failed to extract session token: \(errorMsg)")
                self.onComplete?(false)
                self.close()
                return
            }

            let email = (dict["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Account"

            self.logger.info("Session extracted for \(email)")

            // Create CODEX_HOME and write auth.json.
            let accountsDir = ("~/.codex-accounts" as NSString).expandingTildeInPath
            let uniqueDir = "\(accountsDir)/\(UUID().uuidString.prefix(8))"

            do {
                try FileManager.default.createDirectory(
                    atPath: uniqueDir,
                    withIntermediateDirectories: true)

                let credentials = CodexOAuthCredentials(
                    accessToken: accessToken,
                    refreshToken: "", // Session-based; no refresh token available.
                    idToken: nil,
                    accountId: dict["accountId"] as? String,
                    lastRefresh: Date())

                try CodexOAuthCredentialsStore.save(
                    credentials,
                    env: ["CODEX_HOME": uniqueDir])

                self.logger.info("Saved auth.json to \(uniqueDir)")
            } catch {
                self.logger.error("Failed to save credentials: \(error)")
                try? FileManager.default.removeItem(atPath: uniqueDir)
                self.onComplete?(false)
                self.close()
                return
            }

            // Copy cookies to the per-account persistent data store so dashboard scraping works.
            self.migrateCookiesToPersistentStore(email: email, webView: webView) {
                self.onAccountCreated?(email, uniqueDir)
                self.close()
            }
        }
    }

    /// Copies cookies from the non-persistent (temp) data store to the per-account persistent store.
    private func migrateCookiesToPersistentStore(
        email: String, webView: WKWebView, completion: @escaping () -> Void)
    {
        let sourceStore = webView.configuration.websiteDataStore.httpCookieStore
        let targetStore = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: email)
        let targetCookieStore = targetStore.httpCookieStore

        sourceStore.getAllCookies { cookies in
            let chatgptCookies = cookies.filter { cookie in
                cookie.domain.contains("openai.com") || cookie.domain.contains("chatgpt.com")
            }

            guard !chatgptCookies.isEmpty else {
                completion()
                return
            }

            let group = DispatchGroup()
            for cookie in chatgptCookies {
                group.enter()
                targetCookieStore.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) {
                completion()
            }
        }
    }

    // MARK: - Helpers

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

// MARK: - WKUIDelegate

extension OpenAIDashboardLoginWindowController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil || !(navigationAction.targetFrame?.isMainFrame ?? false) {
            webView.load(navigationAction.request)
        }
        return nil
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
            self.onDismissedWithoutLogin?()
        }

        // Restore the original activation policy only if no other dashboard windows
        // or visible app windows remain. Switching back to .accessory while the
        // Settings window is open would dismiss it.
        let otherDashboardWindows = Self.activeControllers.contains { $0 !== self }
        let hasVisibleWindows = NSApp.windows.contains { win in
            win !== window && win.isVisible && !win.className.contains("StatusBar")
        }
        if !otherDashboardWindows, !hasVisibleWindows,
           let policy = self.previousActivationPolicy
        {
            NSApp.setActivationPolicy(policy)
        }

        Self.activeControllers.removeAll { $0 === self }
        WebKitTeardown.scheduleCleanup(owner: window, window: window, webView: webView)
    }
}
