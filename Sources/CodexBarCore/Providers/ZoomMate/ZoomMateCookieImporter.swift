import Foundation
#if os(macOS)
import SweetCookieKit
#endif

/// Cookie headers narrowed to ZoomMate's fixed request hosts. Keeping the destination in the
/// credential value makes it impossible for host failover to reuse a leaf-host cookie on its
/// sibling host.
public struct ZoomMateCookieHeaders: Codable, Equatable, Sendable {
    static let allowedHosts = ["ai.zoom.us", "zoommate.zoom.us"]

    private let headersByHost: [String: String]

    public init(headersByHost: [String: String]) {
        self.headersByHost = Dictionary(uniqueKeysWithValues: Self.allowedHosts.compactMap { host in
            guard let header = headersByHost[host]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !header.isEmpty
            else {
                return nil
            }
            return (host, header)
        })
    }

    public func header(forHost host: String) -> String? {
        self.headersByHost[host.lowercased()]
    }

    public var isEmpty: Bool {
        self.headersByHost.isEmpty
    }

    func encodedForStorage() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeFromStorage(_ value: String) -> Self? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

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

    public struct SessionInfo: Sendable {
        public let cookieHeaders: ZoomMateCookieHeaders
        public let sourceLabel: String

        public init(cookieHeaders: ZoomMateCookieHeaders, sourceLabel: String) {
            self.cookieHeaders = cookieHeaders
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
                    let cookieHeaders = Self.cookieHeaders(from: cookies)
                    guard !cookieHeaders.isEmpty else { continue }
                    log("\(source.label): found host-scoped cookie headers")
                    sessions.append(SessionInfo(cookieHeaders: cookieHeaders, sourceLabel: source.label))
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        guard !sessions.isEmpty else { throw ZoomMateUsageError.noSession }
        return sessions
    }

    /// Whether a browser would attach a cookie scoped to `cookieDomain` to a request to `host`, per
    /// RFC 6265 domain-matching: a host-only cookie matches its exact host; a
    /// domain cookie (stored with a leading dot) matches that host and all of its subdomains. This
    /// keeps parent `.zoom.us` SSO cookies while preventing an `ai.zoom.us` host-only cookie from
    /// reaching `zoommate.zoom.us` (and vice versa).
    static func isSendable(cookieDomain: String, toHost host: String) -> Bool {
        let normalizedDomain = cookieDomain.lowercased()
        let normalizedHost = host.lowercased()
        guard ZoomMateCookieHeaders.allowedHosts.contains(normalizedHost), !normalizedDomain.isEmpty else {
            return false
        }
        guard normalizedDomain.hasPrefix(".") else { return normalizedHost == normalizedDomain }
        let bareDomain = String(normalizedDomain.dropFirst())
        guard !bareDomain.isEmpty else { return false }
        return normalizedHost == bareDomain || normalizedHost.hasSuffix("." + bareDomain)
    }

    static func cookieHeaders(from cookies: [HTTPCookie]) -> ZoomMateCookieHeaders {
        let pairs: [(String, String)] = ZoomMateCookieHeaders.allowedHosts.compactMap { host in
            let sendable = cookies.filter { Self.isSendable(cookieDomain: $0.domain, toHost: host) }
            guard !sendable.isEmpty else { return nil }
            let header = sendable.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            return (host, header)
        }
        return ZoomMateCookieHeaders(headersByHost: Dictionary(uniqueKeysWithValues: pairs))
    }
}
#endif
