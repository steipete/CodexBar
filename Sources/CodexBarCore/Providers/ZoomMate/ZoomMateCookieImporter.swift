import Foundation
#if os(macOS)
import SweetCookieKit
#endif

#if os(macOS)
private let zoomMateCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.zoommate]?.browserCookieOrder ?? Browser.defaultImportOrder

/// Imports ZoomMate's browser session cookies (not the bearer JWT itself — see
/// `ZoomMateUsageFetcher.mintBearerToken`, which exchanges these cookies for a fresh JWT via
/// ZoomMate's own cookie-to-token bootstrap endpoint). Modeled on `T3ChatCookieImporter`.
public enum ZoomMateCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    /// Includes the parent "zoom.us" domain — ZoomMate's SSO session cookies (`_zm_*`,
    /// `cf_clearance`, etc.) are scoped to the shared parent domain, not the leaf subdomains, and
    /// domain matching here is substring-based (`.contains`), so this one pattern also matches the
    /// leaf domains below; both are kept for clarity. The over-broad `.contains("zoom.us")` read is
    /// then narrowed at send time by `isSendable(toSessionHosts:)`.
    private static let cookieDomains = ["zoommate.zoom.us", "ai.zoom.us", "zoom.us"]

    /// Hosts whose cookies the fetchers actually transmit (the login-bootstrap and credits calls
    /// hit `ai.zoom.us`; the browser session lives on both). Used to drop cookies that a browser
    /// would never attach to these requests — see `isSendable(cookieDomain:)`.
    private static let sessionHosts = ["ai.zoom.us", "zoommate.zoom.us"]

    public struct SessionInfo: Sendable {
        public let cookieHeader: String
        public let sourceLabel: String

        public init(cookieHeader: String, sourceLabel: String) {
            self.cookieHeader = cookieHeader
            self.sourceLabel = sourceLabel
        }
    }

    public static func importSession(
        browserDetection: BrowserDetection,
        logger: (@Sendable (String) -> Void)? = nil) throws -> SessionInfo
    {
        try self.importSessions(browserDetection: browserDetection, logger: logger)[0]
    }

    public static func importSessions(
        browserDetection: BrowserDetection,
        logger: (@Sendable (String) -> Void)? = nil) throws -> [SessionInfo]
    {
        let log: @Sendable (String) -> Void = { msg in logger?("[zoommate-cookie] \(msg)") }
        let installed = zoomMateCookieImportOrder.cookieImportCandidates(using: browserDetection)
        var sessions: [SessionInfo] = []

        for browserSource in installed {
            do {
                let query = BrowserCookieQuery(domains: self.cookieDomains)
                let sources = try self.cookieClient.codexBarRecords(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                        .filter { Self.isSendable(cookieDomain: $0.domain) }
                    guard !cookies.isEmpty else { continue }
                    log("\(source.label): found \(cookies.count) matching cookies")
                    let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    sessions.append(SessionInfo(cookieHeader: header, sourceLabel: source.label))
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        guard !sessions.isEmpty else { throw ZoomMateUsageError.noSession }
        return sessions
    }

    /// Whether a browser would attach a cookie scoped to `cookieDomain` to a request to one of
    /// `sessionHosts`, per RFC 6265 domain-matching: a host-only cookie matches its exact host; a
    /// domain cookie (stored with a leading dot) matches that host and all of its subdomains. This
    /// keeps the parent `.zoom.us` SSO cookies the endpoints need while dropping cookies host-scoped
    /// to unrelated `*.zoom.us` siblings (marketing/support/web) swept in by the coarse `.contains`
    /// domain read above — cookies those endpoints would never receive.
    static func isSendable(cookieDomain: String) -> Bool {
        let bare = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        let normalized = bare.lowercased()
        guard !normalized.isEmpty else { return false }
        return self.sessionHosts.contains { host in
            host == normalized || host.hasSuffix("." + normalized)
        }
    }
}
#endif
