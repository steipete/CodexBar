import Foundation

#if os(macOS)
import SweetCookieKit

public enum MuseCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.provider(.muse, scope: "cookie"))
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = [
        "dev.meta.ai",
        "meta.ai",
    ]

    private static let sessionCookieNames: Set<String> = [
        "ecto_1_sess", "llm_sess", "sessionid", "session_id", "session_token",
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
        public let dashboardURL: URL?
        public let userAgent: String?

        public var cookieHeader: String {
            self.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    public static func importCookieHeader(
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser]? = nil,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo?
    {
        try self.importSessions(
            browserDetection: browserDetection,
            preferredBrowsers: preferredBrowsers,
            logger: logger).first
    }

    public static func importSessions(
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser]? = nil,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        let order = self.resolvedImportOrder(preferredBrowsers)
        let candidates = order.cookieImportCandidates(using: browserDetection)
        let log: (String) -> Void = { message in logger?("[muse-cookie] \(message)") }
        log("Cookie import candidates: \(candidates.map(\.displayName).joined(separator: ", "))")
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
                    guard self.hasAuthenticatedSessionCookie(headerCookies) else {
                        log("Skipping \(source.label): missing Muse session cookie")
                        continue
                    }
                    let cookieNames = Set(headerCookies.map(\.name)).sorted().joined(separator: ", ")
                    log("Found \(headerCookies.count) Muse cookies in \(source.label): \(cookieNames)")
                    sessions.append(SessionInfo(
                        cookies: headerCookies,
                        sourceLabel: source.label,
                        dashboardURL: MuseDashboardURLResolver.mostRecentURL(
                            profileDirectory: URL(fileURLWithPath: source.store.profile.id)),
                        userAgent: self.chromiumUserAgent(browser: browser)))
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                self.log.debug("Muse cookie import failed for \(browser.displayName): \(error)")
                log("\(browser.displayName) cookie import failed: \(error.localizedDescription)")
                continue
            }
        }
        return sessions
    }

    static func resolvedImportOrder(_ preferredBrowsers: [Browser]?) -> [Browser] {
        if let preferredBrowsers, !preferredBrowsers.isEmpty {
            return preferredBrowsers
        }
        return ProviderDefaults.metadata[.muse]?.browserCookieOrder ?? Browser.defaultImportOrder
    }

    static func preferredBrowsers(for source: MuseBrowserSource) -> [Browser]? {
        switch source {
        case .auto: nil
        case .chrome: [.chrome]
        case .brave: [.brave]
        }
    }

    static func dashboardURL(
        sourceLabel: String,
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser]?) -> URL?
    {
        let candidates = self.resolvedImportOrder(preferredBrowsers).cookieImportCandidates(using: browserDetection)
        for browser in candidates {
            guard let store = self.cookieClient.stores(for: browser).first(where: { $0.label == sourceLabel }) else {
                continue
            }
            if let url = MuseDashboardURLResolver.mostRecentURL(
                profileDirectory: URL(fileURLWithPath: store.profile.id))
            {
                return url
            }
        }
        return nil
    }

    static func userAgent(
        sourceLabel: String,
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser]?) -> String?
    {
        let candidates = self.resolvedImportOrder(preferredBrowsers).cookieImportCandidates(using: browserDetection)
        for browser in candidates {
            guard self.cookieClient.stores(for: browser).contains(where: { $0.label == sourceLabel }) else {
                continue
            }
            return self.chromiumUserAgent(browser: browser)
        }
        return nil
    }

    static func chromiumUserAgent(browser: Browser) -> String? {
        let appName = browser.appBundleName + ".app"
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        for root in roots {
            let bundleURL = root.appendingPathComponent(appName, isDirectory: true)
            guard let bundle = Bundle(url: bundleURL),
                  let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  let major = version.split(separator: ".").first,
                  major.allSatisfy(\.isNumber)
            else { continue }
            return self.chromiumUserAgent(majorVersion: String(major))
        }
        return nil
    }

    static func chromiumUserAgent(majorVersion: String) -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(majorVersion).0.0.0 Safari/537.36"
    }

    static func hasAuthenticatedSessionCookie(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { self.sessionCookieNames.contains($0.name.lowercased()) }
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
