import Foundation
import Testing
import WebKit
@testable import CodexBarCore

@Suite
struct OpenAIDashboardNavigationDelegateTests {
    @Test("ignores NSURLErrorCancelled")
    func ignoresCancelledNavigationError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        #expect(NavigationDelegate.shouldIgnoreNavigationError(error))
    }

    @Test("does not ignore non-cancelled URL errors")
    func doesNotIgnoreOtherURLErrors() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(!NavigationDelegate.shouldIgnoreNavigationError(error))
    }

    @MainActor
    @Test("cancelled failure is ignored until finish")
    func cancelledFailureIsIgnoredUntilFinish() {
        let webView = WKWebView()
        var result: Result<Void, Error>?
        let delegate = NavigationDelegate { result = $0 }

        delegate.webView(webView, didFail: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        #expect(result == nil)
        delegate.webView(webView, didFinish: nil)

        switch result {
        case .success?:
            #expect(Bool(true))
        default:
            #expect(Bool(false))
        }
    }

    @MainActor
    @Test("cancelled provisional failure is ignored until real failure")
    func cancelledProvisionalFailureIsIgnoredUntilRealFailure() {
        let webView = WKWebView()
        var result: Result<Void, Error>?
        let delegate = NavigationDelegate { result = $0 }

        delegate.webView(
            webView,
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        #expect(result == nil)

        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        delegate.webView(webView, didFailProvisionalNavigation: nil, withError: timeout)

        switch result {
        case let .failure(error as NSError)?:
            #expect(error.domain == NSURLErrorDomain)
            #expect(error.code == NSURLErrorTimedOut)
        default:
            #expect(Bool(false))
        }
    }
}
