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
    /// match this URL are included. Scope is preserved from BrowserCookieRecord
    /// so host-only cookies are not sent to parent domains.
    static let destinationURL = URL(string: "https://dev.meta.ai/")!
    static let destinationHost = "dev.meta.ai"

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
                    let filteredRecords = source.records.filter { record in
                        guard !record.value.isEmpty else { return false }
                        if let expires = record.expires, expires <= Date() { return false }
                        return self.isSendable(
                            cookieDomain: record.domain,
                            scope: record.scope,
                            toHost: self.destinationHost)
                            && self.isPathApplicable(record.path, to: self.destinationURL.path)
                            && (!record.isSecure || self.destinationURL.scheme?.lowercased() == "https")
                    }
                    guard !filteredRecords.isEmpty else { continue }
                    let cookies = BrowserCookieClient.makeHTTPCookies(filteredRecords, origin: query.origin)
                    let headerCookies = cookies
                        .filter { !$0.value.isEmpty && $0.expiresDate.map { $0 > Date() } ?? true }
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

    // MARK: - Cookie isolation (testable) — preserves BrowserCookieRecord.scope

    /// Whether a browser would attach a cookie to `host`, per RFC 6265 domain-matching.
    /// Scope is carried separately because Chromium normalizes `.example.com` and `example.com`
    /// to the same domain string when records become `HTTPCookie` values.
    static func isSendable(cookieDomain: String, scope: BrowserCookieScope, toHost host: String) -> Bool {
        let normalizedDomain = cookieDomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix(".")
            .lowercased()
        let normalizedHost = host.lowercased()
        guard !normalizedDomain.isEmpty else { return false }
        switch scope {
        case .hostOnly:
            return normalizedHost == normalizedDomain
        case .domain:
            return normalizedHost == normalizedDomain || normalizedHost.hasSuffix("." + normalizedDomain)
        }
    }

    static func isPathApplicable(_ cookiePath: String, to requestPath: String) -> Bool {
        let req = requestPath.isEmpty ? "/" : requestPath
        if req.hasPrefix(cookiePath) { return true }
        return cookiePath == "/"
    }

    /// Legacy HTTPCookie-based filter kept for unit tests that construct HTTPCookie directly.
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
        if !requestPath.hasPrefix(cookiePath) {
            if cookiePath != "/" { return false }
        }
        if cookie.isSecure, url.scheme?.lowercased() != "https" { return false }
        return true
    }
}
#endif
