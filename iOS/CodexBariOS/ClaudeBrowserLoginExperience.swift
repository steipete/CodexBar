import CodexBariOSShared
import Foundation
import Observation
import SwiftUI
import WebKit

@MainActor
@Observable
final class ClaudeBrowserLoginViewModel: NSObject {
    let session: DashboardModel.ClaudeLoginSession

    var isLoading = true
    var progress: Double = 0
    var pageTitle = "Claude Login"
    var statusLine = "Finish signing in to Claude. The app will save the `claude.ai` web session automatically."
    var canGoBack = false
    var canGoForward = false

    private let onComplete: (Result<ClaudeWebSession, Error>) -> Void
    private var hasLoadedRequest = false
    private var hasFinished = false
    private weak var webView: WKWebView?
    private var observedCookieStore: WKHTTPCookieStore?

    init(
        session: DashboardModel.ClaudeLoginSession,
        onComplete: @escaping (Result<ClaudeWebSession, Error>) -> Void)
    {
        self.session = session
        self.onComplete = onComplete
        super.init()
    }

    func attach(webView: WKWebView) {
        self.webView = webView

        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        if self.observedCookieStore !== cookieStore {
            self.observedCookieStore?.remove(self)
            self.observedCookieStore = cookieStore
            cookieStore.add(self)
        }

        self.syncNavigationState(for: webView)
    }

    func loadIfNeeded() {
        guard !self.hasLoadedRequest, let webView else { return }
        self.hasLoadedRequest = true
        webView.load(URLRequest(url: self.session.entryURL))
    }

    func goBack() {
        self.webView?.goBack()
    }

    func goForward() {
        self.webView?.goForward()
    }

    func reload() {
        self.webView?.reload()
    }

    private func syncNavigationState(for webView: WKWebView) {
        self.canGoBack = webView.canGoBack
        self.canGoForward = webView.canGoForward
        self.progress = webView.estimatedProgress
        self.isLoading = webView.isLoading
        if let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            self.pageTitle = title
        }
    }

    private func updateWaitingStatus(for webView: WKWebView?) {
        let host = webView?.url?.host?.lowercased() ?? ""
        if host.contains("claude.ai") {
            self.statusLine = "Finish signing in on this Claude page. The app will continue as soon as the web session cookie appears."
        } else {
            self.statusLine = "Claude may open another auth page. Approve access and return here if needed."
        }
    }

    private func inspectSessionCookies() async {
        guard !self.hasFinished, let cookieStore = self.observedCookieStore else { return }

        let cookies = await cookieStore.allCookies()
        if let sessionKey = Self.sessionKey(in: cookies) {
            self.statusLine = "Claude web session detected. Saving login…"
            self.finish(.success(ClaudeWebSession(sessionKey: sessionKey)))
            return
        }

        self.updateWaitingStatus(for: self.webView)
    }

    private static func sessionKey(in cookies: [HTTPCookie]) -> String? {
        for cookie in cookies where cookie.name == "sessionKey" {
            let domain = cookie.domain.lowercased()
            guard domain.contains("claude.ai") else { continue }

            let value = cookie.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func handleNavigationError(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }
        self.finish(.failure(error))
    }

    private func finish(_ result: Result<ClaudeWebSession, Error>) {
        guard !self.hasFinished else { return }
        self.hasFinished = true
        self.onComplete(result)
    }
}

extension ClaudeBrowserLoginViewModel: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        self.syncNavigationState(for: webView)
        self.updateWaitingStatus(for: webView)
    }

    func webView(_ webView: WKWebView, didCommit _: WKNavigation!) {
        self.syncNavigationState(for: webView)
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        self.syncNavigationState(for: webView)
        Task {
            await self.inspectSessionCookies()
        }
    }

    func webView(
        _: WKWebView,
        didFail _: WKNavigation!,
        withError error: Error)
    {
        self.handleNavigationError(error)
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError error: Error)
    {
        self.handleNavigationError(error)
    }
}

extension ClaudeBrowserLoginViewModel: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in _: WKHTTPCookieStore) {
        Task { @MainActor in
            await self.inspectSessionCookies()
        }
    }
}

struct ClaudeBrowserLoginExperience: View {
    @Environment(\.colorScheme) private var colorScheme
    let session: DashboardModel.ClaudeLoginSession
    let onCancel: () -> Void
    let onComplete: (Result<ClaudeWebSession, Error>) -> Void

    @State private var model: ClaudeBrowserLoginViewModel

    init(
        session: DashboardModel.ClaudeLoginSession,
        onCancel: @escaping () -> Void,
        onComplete: @escaping (Result<ClaudeWebSession, Error>) -> Void)
    {
        self.session = session
        self.onCancel = onCancel
        self.onComplete = onComplete
        self._model = State(initialValue: ClaudeBrowserLoginViewModel(session: session, onComplete: onComplete))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ClaudeLoginBackdrop()

                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Sign in to Claude")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("Use the real Claude web flow here. As soon as a valid `claude.ai` session cookie appears, the app will save it and refresh usage automatically.")
                            .foregroundStyle(.secondary)
                        Text(self.model.statusLine)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color(uiColor: .tertiarySystemBackground).opacity(self.colorScheme == .dark ? 0.96 : 0.82)))
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(uiColor: .secondarySystemBackground),
                                        Color(uiColor: .tertiarySystemBackground),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing))
                            .overlay(
                                RoundedRectangle(cornerRadius: 28, style: .continuous)
                                    .stroke(Color.white.opacity(self.colorScheme == .dark ? 0.08 : 0.4), lineWidth: 1)))
                    .shadow(color: Color.black.opacity(self.colorScheme == .dark ? 0.24 : 0.06), radius: 18, y: 8)

                    VStack(spacing: 0) {
                        if self.model.isLoading {
                            ProgressView(value: max(self.model.progress, 0.05), total: 1)
                                .tint(Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255))
                                .padding(.horizontal, 18)
                                .padding(.top, 16)
                        } else {
                            Color.clear
                                .frame(height: 12)
                        }

                        ClaudeBrowserWebView(model: self.model)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255).opacity(0.16), lineWidth: 1))
                            .padding(18)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground).opacity(self.colorScheme == .dark ? 0.98 : 0.86)))
                    .shadow(color: Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255).opacity(self.colorScheme == .dark ? 0.16 : 0.12), radius: 20, y: 10)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        self.onCancel()
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(self.model.pageTitle)
                        .font(.headline)
                        .lineLimit(1)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        self.model.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!self.model.canGoBack)

                    Button {
                        self.model.goForward()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!self.model.canGoForward)

                    Button {
                        self.model.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }
}

private struct ClaudeBrowserWebView: UIViewRepresentable {
    let model: ClaudeBrowserLoginViewModel

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self.model
        webView.uiDelegate = self.model
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive
        webView.backgroundColor = .clear
        webView.isOpaque = false
        webView.scrollView.backgroundColor = .clear
        self.model.attach(webView: webView)
        self.model.loadIfNeeded()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context _: Context) {
        self.model.attach(webView: webView)
        self.model.loadIfNeeded()
    }
}

private struct ClaudeLoginBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: [
                Color(uiColor: self.colorScheme == .dark ? .systemGroupedBackground : .systemBackground),
                Color(uiColor: self.colorScheme == .dark ? .secondarySystemGroupedBackground : .secondarySystemBackground),
                Color(uiColor: self.colorScheme == .dark ? .systemGroupedBackground : .systemGroupedBackground),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
        .overlay(alignment: .topLeading) {
            Circle()
                .fill(Color.white.opacity(self.colorScheme == .dark ? 0.08 : 0.34))
                .frame(width: 240, height: 240)
                .blur(radius: 20)
                .offset(x: -60, y: -40)
        }
        .ignoresSafeArea()
    }
}

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            self.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}
