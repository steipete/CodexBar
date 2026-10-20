#if os(macOS)
import Foundation
import WebKit

/// Stops JavaScript that cannot service navigation or pending evaluation callbacks.
@MainActor
enum WebKitContentProcess {
    private static let log = CodexBarLog.logger(LogCategories.webkitTeardown)

    @discardableResult
    static func terminate(_ webView: WKWebView) -> Bool {
        // WebKit SPI also fails pending evaluations, allowing their callers to unwind.
        let selector = NSSelectorFromString("_killWebContentProcessAndResetState")
        guard webView.responds(to: selector) else {
            self.log.warning("WebContent process termination unavailable")
            return false
        }
        webView.perform(selector)
        self.log.warning("WebContent process terminated")
        return true
    }
}
#endif
