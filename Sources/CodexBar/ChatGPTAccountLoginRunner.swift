import AppKit
import CodexBarCore
import Foundation
import WebKit

@MainActor
final class ChatGPTAccountLoginRunner: NSObject {
    enum Phase: Sendable {
        case loading
        case waitingLogin
        case capturing
        case success
        case failed(String)
    }

    struct Result: Sendable {
        enum Outcome: Sendable {
            case success(cookieHeader: String, email: String?, workspaceLabel: String?)
            case cancelled
            case failed(String)
        }

        let outcome: Outcome
    }

    private let browserDetection: BrowserDetection
    private let logger = CodexBarLog.logger(LogCategories.openAIWeb)
    private var webView: WKWebView?
    private var window: NSWindow?
    private var continuation: CheckedContinuation<Result, Never>?
    private var phaseCallback: ((Phase) -> Void)?
    private var isCompleting = false
    private var captureTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var debugLines: [String] = []

    private static let initialURL = URL(string: "https://chatgpt.com/")!
    private static let loginHosts = ["auth.openai.com", "auth.chatgpt.com"]
    private static let timeoutSeconds: UInt64 = 120

    init(browserDetection: BrowserDetection) {
        self.browserDetection = browserDetection
        super.init()
    }

    private func log(_ message: String) {
        let stamped = "[chatgpt-login] \(message)"
        self.logger.info("\(stamped)")
        self.debugLines.append(stamped)
        if self.debugLines.count > 200 {
            self.debugLines.removeFirst(self.debugLines.count - 200)
        }
    }

    private func debugDump() -> String {
        self.debugLines.joined(separator: "\n")
    }

    func run(onPhaseChange: @escaping @Sendable (Phase) -> Void) async -> Result {
        WebKitTeardown.retain(self)
        self.phaseCallback = onPhaseChange
        onPhaseChange(.loading)
        self.log("login flow started")

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.setupWindow()
        }
    }

    private func setupWindow() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 760), configuration: config)
        webView.navigationDelegate = self
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Add ChatGPT Account"
        window.contentView = webView
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.startPollingForSession()
        self.startTimeoutWatchdog()
        self.log("window opened")

        webView.load(URLRequest(url: Self.initialURL))
    }

    private func scheduleCleanup() {
        self.captureTask?.cancel()
        self.pollingTask?.cancel()
        self.timeoutTask?.cancel()
        WebKitTeardown.scheduleCleanup(owner: self, window: self.window, webView: self.webView)
    }

    private func complete(with result: Result) {
        guard !self.isCompleting, let continuation = self.continuation else { return }
        self.isCompleting = true
        self.continuation = nil
        self.scheduleCleanup()
        continuation.resume(returning: result)
    }

    private func currentPhase(for url: URL?) -> Phase {
        guard let host = url?.host?.lowercased() else { return .loading }
        if Self.loginHosts.contains(host) { return .waitingLogin }
        if host.contains("chatgpt.com") || host.contains("openai.com") { return .capturing }
        return .loading
    }

    private func startPollingForSession() {
        self.pollingTask?.cancel()
        self.pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.isCompleting {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, !self.isCompleting else { return }
                await self.attemptCapture()
            }
        }
    }

    private func startTimeoutWatchdog() {
        self.timeoutTask?.cancel()
        self.timeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.timeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled, !self.isCompleting else { return }
            self.log("timed out waiting for captured session")
            self.phaseCallback?(.failed("Timed out waiting for ChatGPT session"))
            self.complete(with: Result(outcome: .failed(self.debugDump())))
        }
    }

    private func scheduleCaptureAttempt() {
        self.captureTask?.cancel()
        self.captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.phaseCallback?(.capturing)
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await self.attemptCapture()
        }
    }

    private func attemptCapture() async {
        guard let webView = self.webView, !self.isCompleting else { return }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let relevant = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            return domain.contains("chatgpt.com") || domain.contains("openai.com")
        }
        guard !relevant.isEmpty else {
            self.log("capture attempt: 0 relevant cookies")
            return
        }

        let cookieNames = relevant.map(\.name).sorted().joined(separator: ", ")
        self.log("capture attempt: \(relevant.count) relevant cookies [\(cookieNames)]")

        let header = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let apiEmail = await self.fetchSignedInEmail(from: relevant)?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let workspaceLabel = self.resolveWorkspaceLabel(from: relevant)
        if let workspaceLabel, !workspaceLabel.isEmpty {
            self.log("resolved workspace label: \(workspaceLabel)")
        }

        if let apiEmail, !apiEmail.isEmpty {
            self.log("session API identified signed-in account: \(apiEmail)")
            if self.hasLikelySessionCookies(relevant) {
                self.log("captured signed-in API session with session cookies")
                await self.persistCapturedCookies(
                    relevant,
                    accountEmail: apiEmail,
                    workspaceLabel: workspaceLabel)
                self.phaseCallback?(.success)
                self.complete(with: Result(outcome: .success(
                    cookieHeader: header,
                    email: apiEmail,
                    workspaceLabel: workspaceLabel)))
                return
            }
        }

        let importer = OpenAIDashboardBrowserCookieImporter(browserDetection: self.browserDetection)
        do {
            let result = try await importer.importManualCookies(
                cookieHeader: header,
                intoAccountEmail: nil,
                intoWorkspaceLabel: workspaceLabel,
                allowAnyAccount: true,
                logger: { [weak self] line in self?.log(line) })
            let resolvedEmail = result.signedInEmail?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let labelEmail = (resolvedEmail?.isEmpty == false) ? resolvedEmail : apiEmail
            self.log("importer validated session as \(labelEmail ?? "unknown")")
            self.phaseCallback?(.success)
            self.complete(with: Result(outcome: .success(
                cookieHeader: header,
                email: labelEmail,
                workspaceLabel: workspaceLabel)))
        } catch let error as OpenAIDashboardBrowserCookieImporter.ImportError {
            self.log("importer validation failed: \(error.localizedDescription)")
            switch error {
            case .manualCookieHeaderInvalid, .dashboardStillRequiresLogin, .noMatchingAccount:
                self.phaseCallback?(.capturing)
                return
            case .noCookiesFound, .browserAccessDenied:
                self.phaseCallback?(.failed(error.localizedDescription))
                self.complete(with: Result(outcome: .failed(error.localizedDescription)))
            }
        } catch {
            self.log("capture validation error: \(error.localizedDescription)")
            self.phaseCallback?(.capturing)
            return
        }
    }

    private func hasLikelySessionCookies(_ cookies: [HTTPCookie]) -> Bool {
        for cookie in cookies {
            let name = cookie.name.lowercased()
            if name.contains("session-token") || name.contains("authjs") || name.contains("next-auth") {
                return true
            }
            if name == "_account" || name == "oai-client-auth-session" { return true }
        }
        return false
    }

    private func persistCapturedCookies(
        _ cookies: [HTTPCookie],
        accountEmail: String,
        workspaceLabel: String?) async
    {
        let store = OpenAIDashboardWebsiteDataStore.store(
            forAccountEmail: accountEmail,
            workspaceLabel: workspaceLabel)
        await self.clearChatGPTCookies(in: store)
        await self.setCookies(cookies, into: store)
        self.log("persisted captured cookies for \(accountEmail)\(workspaceLabel.map { " [\($0)]" } ?? "")")
    }

    private func resolveWorkspaceLabel(from cookies: [HTTPCookie]) -> String? {
        guard let accountID = cookies.first(where: { $0.name == "_account" })?.value,
              !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let sessionCookie = cookies.first(where: { $0.name == "oai-client-auth-session" })?.value,
              let payload = self.decodeBase64URLJSONPayload(fromCookieValue: sessionCookie),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let workspaces = json["workspaces"] as? [[String: Any]]
        else {
            return nil
        }

        guard let workspace = workspaces.first(where: {
            ($0["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == accountID
        }) else {
            return nil
        }

        let name = (workspace["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty { return name }

        let kind = (workspace["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if kind == "personal" { return "Personal" }
        return nil
    }

    private func decodeBase64URLJSONPayload(fromCookieValue value: String) -> Data? {
        let prefix = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? value
        guard !prefix.isEmpty else { return nil }
        var base64 = prefix.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private func clearChatGPTCookies(in store: WKWebsiteDataStore) async {
        await withCheckedContinuation { cont in
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                let filtered = records.filter { record in
                    let name = record.displayName.lowercased()
                    return name.contains("chatgpt.com") || name.contains("openai.com")
                }
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: filtered) {
                    cont.resume()
                }
            }
        }
    }

    private func setCookies(_ cookies: [HTTPCookie], into store: WKWebsiteDataStore) async {
        for cookie in cookies {
            await withCheckedContinuation { cont in
                store.httpCookieStore.setCookie(cookie) { cont.resume() }
            }
        }
    }

    private func fetchSignedInEmail(from cookies: [HTTPCookie]) async -> String? {
        let chatgptCookies = cookies.filter { $0.domain.lowercased().contains("chatgpt.com") }
        guard !chatgptCookies.isEmpty else {
            self.log("session API skipped: no chatgpt.com cookies")
            return nil
        }

        let cookieHeader = chatgptCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let endpoints = [
            "https://chatgpt.com/backend-api/me",
            "https://chatgpt.com/api/auth/session",
        ]

        for urlString in endpoints {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                self.log("session API \(url.path) status=\(status)")
                guard status >= 200, status < 300 else { continue }
                if let email = Self.findFirstEmail(inJSONData: data) {
                    return email.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                }
            } catch {
                self.log("session API request failed for \(url.path): \(error.localizedDescription)")
            }
        }

        return nil
    }

    private static func findFirstEmail(inJSONData data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        var queue: [Any] = [json]
        var seen = 0
        while !queue.isEmpty, seen < 2000 {
            let cur = queue.removeFirst()
            seen += 1
            if let str = cur as? String, str.contains("@") { return str }
            if let dict = cur as? [String: Any] {
                for (k, v) in dict {
                    if k.lowercased() == "email", let s = v as? String, s.contains("@") { return s }
                    queue.append(v)
                }
            } else if let arr = cur as? [Any] {
                queue.append(contentsOf: arr)
            }
        }
        return nil
    }
}

extension ChatGPTAccountLoginRunner: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let phase = self.currentPhase(for: webView.url)
            let urlString = webView.url?.absoluteString ?? "unknown"
            self.log(
                "didFinish navigation url=\(urlString) phase=\(String(describing: phase))")
            self.phaseCallback?(phase)
            if case .waitingLogin = phase { return }
            self.scheduleCaptureAttempt()
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!)
    {
        Task { @MainActor in
            let phase = self.currentPhase(for: webView.url)
            self.log("redirect url=\(webView.url?.absoluteString ?? "unknown") phase=\(String(describing: phase))")
            self.phaseCallback?(phase)
            if case .waitingLogin = phase { return }
            self.scheduleCaptureAttempt()
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error)
    {
        Task { @MainActor in
            self.phaseCallback?(.failed(error.localizedDescription))
            self.complete(with: Result(outcome: .failed(error.localizedDescription)))
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error)
    {
        Task { @MainActor in
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                return
            }
            self.phaseCallback?(.failed(error.localizedDescription))
            self.complete(with: Result(outcome: .failed(error.localizedDescription)))
        }
    }
}

extension ChatGPTAccountLoginRunner: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            guard !self.isCompleting else { return }
            self.complete(with: Result(outcome: .cancelled))
        }
    }
}
