#if os(macOS)
import Foundation
import WebKit

// MARK: - Navigation helper (revived from the old credits scraper)

@MainActor
final class NavigationDelegate: NSObject, WKNavigationDelegate {
    private let completion: (Result<Void, Error>) -> Void
    private var hasCompleted: Bool = false
    static var associationKey: UInt8 = 0

    init(completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.completeOnce(.success(()))
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
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func completeOnce(_ result: Result<Void, Error>) {
        guard !self.hasCompleted else { return }
        self.hasCompleted = true
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
