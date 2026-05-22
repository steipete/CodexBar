#if os(macOS)
import Foundation
import WebKit

// MARK: - Navigation helper (revived from the old credits scraper)

@MainActor
final class NavigationDelegate: NSObject, WKNavigationDelegate {
    private let completion: (Result<Void, Error>) -> Void
    private var hasCompleted: Bool = false
    private var timeoutWorkItem: DispatchWorkItem?
    private var postCommitWorkItem: DispatchWorkItem?
    static var associationKey: UInt8 = 0
    nonisolated static let postCommitSuccessDelay: TimeInterval = 0.75

    init(completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
    }

    func armTimeout(seconds: TimeInterval) {
        self.timeoutWorkItem?.cancel()
        let delay = max(seconds, 0)
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.completeOnce(.failure(URLError(.timedOut)))
            }
        }
        self.timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.completeOnce(.success(()))
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !self.hasCompleted else { return }
        self.postCommitWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.completeOnce(.success(()))
            }
        }
        self.postCommitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.postCommitSuccessDelay, execute: workItem)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if Self.shouldIgnoreNavigationError(error) { return }
        self.completeOnce(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if Self.shouldIgnoreNavigationError(error) { return }
        self.completeOnce(.failure(error))
    }

    nonisolated static func shouldIgnoreNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }

        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 {
            return true
        }

        return false
    }

    private func completeOnce(_ result: Result<Void, Error>) {
        guard !self.hasCompleted else { return }
        self.hasCompleted = true
        self.timeoutWorkItem?.cancel()
        self.timeoutWorkItem = nil
        self.postCommitWorkItem?.cancel()
        self.postCommitWorkItem = nil
        self.completion(result)
    }
}

extension WKWebView {
    var codexNavigationDelegate: NavigationDelegate? {
        get {
            objc_getAssociatedObject(self, &NavigationDelegate.associationKey) as? NavigationDelegate
        }
        set {
            objc_setAssociatedObject(
                self,
                &NavigationDelegate.associationKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

#endif
