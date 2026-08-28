import Foundation

extension CursorStatusProbe {
    /// The exact browser session accepted by Cursor's API, before it is committed to local cache.
    public struct BrowserLoginSession: Sendable {
        let cookieHeader: String
        let sourceLabel: String
    }

    public struct BrowserLoginResult: Sendable {
        public let snapshot: CursorStatusSnapshot
        public let session: BrowserLoginSession

        public var sourceLabel: String {
            self.session.sourceLabel
        }
    }
}

#if os(macOS) || os(Linux)
extension CursorStatusProbe {
    /// Stores the browser session selected by the user after candidate discovery completes.
    @discardableResult
    public static func commitBrowserLoginSession(_ session: BrowserLoginSession) -> Bool {
        CookieHeaderCache.storeResult(
            provider: .cursor,
            cookieHeader: session.cookieHeader,
            sourceLabel: session.sourceLabel,
            authenticationFailurePolicy: .stopFallback)
    }
}
#else
extension CursorStatusProbe {
    @discardableResult
    public static func commitBrowserLoginSession(_: BrowserLoginSession) -> Bool {
        false
    }
}
#endif
