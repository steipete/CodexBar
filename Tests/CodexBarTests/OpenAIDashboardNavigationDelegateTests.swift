import Foundation
import Testing
import WebKit
@testable import CodexBarCore

struct OpenAIDashboardNavigationDelegateTests {
    final class DelegateBox: @unchecked Sendable {
        var delegate: NavigationDelegate?
    }

    @Test
    func `ignores NSURLErrorCancelled`() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        #expect(NavigationDelegate.shouldIgnoreNavigationError(error))
    }

    @Test
    func `ignores WebKit frame load interrupted by policy change`() {
        let error = NSError(domain: "WebKitErrorDomain", code: 102)
        #expect(NavigationDelegate.shouldIgnoreNavigationError(error))
    }

    @Test
    func `does not ignore non-cancelled URL errors`() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(!NavigationDelegate.shouldIgnoreNavigationError(error))
    }

    @MainActor
    @Test
    func `cancelled failure is ignored until finish`() {
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
    @Test
    func `commit completes navigation successfully after grace period`() async {
        let webView = WKWebView()
        var result: Result<Void, Error>?
        let box = DelegateBox()
        box.delegate = NavigationDelegate { result = $0 }

        box.delegate?.webView(webView, didCommit: nil)
        #expect(result == nil)

        try? await Task.sleep(nanoseconds: UInt64((NavigationDelegate.postCommitSuccessDelay + 0.1) * 1_000_000_000))
        box.delegate = nil

        switch result {
        case .success?:
            #expect(Bool(true))
        default:
            #expect(Bool(false))
        }
    }

    @MainActor
    @Test
    func `post commit failure wins before delayed success`() async {
        let webView = WKWebView()
        var result: Result<Void, Error>?
        let box = DelegateBox()
        box.delegate = NavigationDelegate { result = $0 }

        box.delegate?.webView(webView, didCommit: nil)
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        box.delegate?.webView(webView, didFail: nil, withError: timeout)

        try? await Task.sleep(nanoseconds: UInt64((NavigationDelegate.postCommitSuccessDelay + 0.1) * 1_000_000_000))
        box.delegate = nil

        switch result {
        case let .failure(error as NSError)?:
            #expect(error.domain == NSURLErrorDomain)
            #expect(error.code == NSURLErrorTimedOut)
        default:
            #expect(Bool(false))
        }
    }

    @MainActor
    @Test
    func `cancelled provisional failure is ignored until real failure`() {
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

    @MainActor
    @Test
    func `frame load interrupted provisional failure is ignored until finish`() {
        let webView = WKWebView()
        var result: Result<Void, Error>?
        let delegate = NavigationDelegate { result = $0 }

        delegate.webView(
            webView,
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: "WebKitErrorDomain", code: 102))
        #expect(result == nil)

        delegate.webView(webView, didFinish: nil)

        switch result {
        case .success?:
            #expect(Bool(true))
        default:
            #expect(Bool(false))
        }
    }

    @Test
    func `navigation timeout fails with timed out error`() async {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, Error>, Never>) in
            Task { @MainActor in
                let box = DelegateBox()
                box.delegate = NavigationDelegate { result in
                    continuation.resume(returning: result)
                    box.delegate = nil
                }
                box.delegate?.armTimeout(seconds: 0.01)
            }
        }

        switch result {
        case let .failure(error as URLError):
            #expect(error.code == .timedOut)
        default:
            #expect(Bool(false))
        }
    }
}
