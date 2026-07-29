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
    /// Includes the parent "zoom.us" domain because ZoomMate's SSO session uses both parent-domain
    /// and leaf-host cookies. The reader recovers Chromium's host-only metadata before these
    /// candidates are narrowed to the two fixed request hosts.
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
                let sources = try ZoomMateChromiumCookieScopeReader.read(
                    matching: query,
                    in: browserSource,
                    cookieClient: self.cookieClient,
                    logger: log)
                for source in sources where !source.cookies.isEmpty {
                    let cookieHeaders = Self.cookieHeaders(from: source.cookies)
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

    /// Whether a browser would attach a cookie to `host`, using Chromium's recovered host-only flag
    /// and RFC 6265 domain matching. Only root-path cookies are retained because the cached header
    /// is reused across ZoomMate's login, status, and history routes.
    static func isSendable(
        cookieDomain: String,
        hostOnly: Bool,
        path: String,
        toHost host: String) -> Bool
    {
        let normalizedDomain = cookieDomain.lowercased()
        let normalizedHost = host.lowercased()
        guard ZoomMateCookieHeaders.allowedHosts.contains(normalizedHost),
              !normalizedDomain.isEmpty,
              path == "/"
        else {
            return false
        }
        if hostOnly {
            return normalizedHost == normalizedDomain
        }
        return normalizedHost == normalizedDomain || normalizedHost.hasSuffix("." + normalizedDomain)
    }

    static func cookieHeaders(
        from cookies: [ZoomMateChromiumCookieScopeReader.ScopedCookie]) -> ZoomMateCookieHeaders
    {
        let pairs: [(String, String)] = ZoomMateCookieHeaders.allowedHosts.compactMap { host in
            let sendable = cookies.filter {
                Self.isSendable(
                    cookieDomain: $0.record.domain,
                    hostOnly: $0.scope == .hostOnly,
                    path: $0.record.path,
                    toHost: host)
            }
            guard !sendable.isEmpty else { return nil }
            let header = sendable.map { "\($0.record.name)=\($0.record.value)" }.joined(separator: "; ")
            return (host, header)
        }
        return ZoomMateCookieHeaders(headersByHost: Dictionary(uniqueKeysWithValues: pairs))
    }
}
#endif
