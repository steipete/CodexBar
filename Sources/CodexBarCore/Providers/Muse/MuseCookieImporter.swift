import Foundation

#if os(macOS)
import SweetCookieKit

public enum MuseCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.provider(.muse, scope: "cookie"))
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = [
        "dev.meta.ai",
        "ai.developer.meta.com",
        "developer.meta.com",
        "www.meta.ai",
        "meta.ai",
        // Comet/FB infra — dev.meta.ai auth rides on facebook.com cookies (c_user/xs/datr/fb_dtsg)
        "facebook.com",
        "www.facebook.com",
        "meta.com",
        "www.meta.com",
    ]

    private static let sessionCookieNames: Set<String> = [
        "sessionid", "session_id", "session_token", "c_user", "xs", "fbsr", "datr",
    ]

    /// Destination for which the Cookie header will be sent. Filters to preserve
    /// browser cookie isolation per RFC 6265 — only cookies whose domain/path
    /// match this URL are included.
    static let destinationURL = URL(string: "https://dev.meta.ai/")!

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String

        public var cookieHeader: String {
            self.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    public static func importCookieHeader(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo?
    {
        let sessions = try self.importSessions(browserDetection: browserDetection, logger: logger)
        return sessions.max(by: { $0.cookies.count < $1.cookies.count })
    }

    public static func importSessions(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        let order = ProviderDefaults.metadata[.muse]?.browserCookieOrder ?? Browser.defaultImportOrder
        let candidates = order.cookieImportCandidates(using: browserDetection)
        var sessions: [SessionInfo] = []
        for browser in candidates {
            do {
                let query = BrowserCookieQuery(domains: self.cookieDomains)
                let sources = try self.cookieClient.codexBarRecords(
                    matching: query,
                    in: browser,
                    logger: logger)
                for source in sources where !source.records.isEmpty {
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    let headerCookies = self.filteredCookiesForDestination(cookies, at: self.destinationURL)
                    guard !headerCookies.isEmpty else { continue }
                    sessions.append(SessionInfo(cookies: headerCookies, sourceLabel: source.label))
                }
            } catch {
                self.log.debug("Muse cookie import failed for \(browser.displayName): \(error)")
                continue
            }
        }
        return sessions
    }

    // MARK: - Cookie isolation (testable)

    /// Filters cookies to those that a browser would attach to a request for `url`.
    /// Used to avoid concatenating cross-origin cookies (e.g. unrelated facebook.com
    /// cookies) into the `dev.meta.ai` Cookie header.
    static func filteredCookiesForDestination(_ cookies: [HTTPCookie], at url: URL) -> [HTTPCookie] {
        cookies.filter { cookie in
            guard !cookie.value.isEmpty else { return false }
            if let expires = cookie.expiresDate, expires <= Date() { return false }
            return self.isCookieApplicable(cookie, to: url)
        }
    }

    static func isCookieApplicable(_ cookie: HTTPCookie, to url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        var cookieDomain = cookie.domain.lowercased()
        if cookieDomain.hasPrefix(".") { cookieDomain.removeFirst() }
        let hostMatches: Bool = {
            if host == cookieDomain { return true }
            return host.hasSuffix("." + cookieDomain)
        }()
        guard hostMatches else { return false }

        let cookiePath = cookie.path
        let requestPath = url.path.isEmpty ? "/" : url.path
        // Cookie path must be a prefix of request path per RFC 6265 §5.1.4
        if !requestPath.hasPrefix(cookiePath) {
            // Special-case: "/" matches everything
            if cookiePath != "/" { return false }
        }
        if cookie.isSecure, url.scheme?.lowercased() != "https" { return false }
        return true
    }
}
#endif
