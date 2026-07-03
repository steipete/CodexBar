import Foundation

#if os(macOS)
import SweetCookieKit

public enum QoderCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.qoderCookie)
    private static let cookieClient = BrowserCookieClient()
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.qoder]?.browserCookieOrder ?? Browser.defaultImportOrder

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String
        public let site: QoderWebSite

        public init(cookies: [HTTPCookie], sourceLabel: String, site: QoderWebSite) {
            self.cookies = cookies
            self.sourceLabel = sourceLabel
            self.site = site
        }

        public var cookieHeader: String {
            self.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    public static func importSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        preferredBrowsers: [Browser] = [],
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        guard let session = try self.importSessions(
            browserDetection: browserDetection,
            preferredBrowsers: preferredBrowsers,
            logger: logger).first
        else {
            throw QoderUsageError.missingCredentials
        }
        return session
    }

    public static func importSessions(
        browserDetection: BrowserDetection = BrowserDetection(),
        preferredBrowsers: [Browser] = [],
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        let installedBrowsers = preferredBrowsers.isEmpty
            ? self.cookieImportOrder.cookieImportCandidates(using: browserDetection)
            : preferredBrowsers.cookieImportCandidates(using: browserDetection)
        var sessions: [SessionInfo] = []

        for browserSource in installedBrowsers {
            for site in QoderWebSite.allCases {
                do {
                    let query = Self.cookieQuery(for: site)
                    let sources = try Self.cookieClient.codexBarRecords(
                        matching: query,
                        in: browserSource,
                        logger: { msg in self.emit(msg, logger: logger) })
                    for source in sources where !source.records.isEmpty {
                        let records = self.records(source.records, for: site)
                        let cookies = BrowserCookieClient.makeHTTPCookies(records, origin: query.origin)
                        guard !cookies.isEmpty else { continue }
                        self.emit("Found \(cookies.count) cookies in \(source.label)", logger: logger)
                        sessions.append(SessionInfo(cookies: cookies, sourceLabel: source.label, site: site))
                    }
                } catch {
                    BrowserCookieAccessGate.recordIfNeeded(error)
                    self.emit(
                        "\(browserSource.displayName) cookie import failed: \(error.localizedDescription)",
                        logger: logger)
                }
            }
        }

        guard !sessions.isEmpty else {
            throw QoderUsageError.missingCredentials
        }
        return sessions
    }

    static func cookieQuery(for site: QoderWebSite) -> BrowserCookieQuery {
        BrowserCookieQuery(domains: site.cookieDomains, domainMatch: .exact)
    }

    static func records(_ records: [BrowserCookieRecord], for site: QoderWebSite) -> [BrowserCookieRecord] {
        records.filter { record in
            self.cookieDomainMatchesSite(record.domain, site: site)
        }
    }

    private static func cookieDomainMatchesSite(_ rawDomain: String, site: QoderWebSite) -> Bool {
        let domain = self.normalizedCookieDomain(rawDomain)
        return site.cookieDomains.contains { self.normalizedCookieDomain($0) == domain }
    }

    private static func normalizedCookieDomain(_ rawDomain: String) -> String {
        let trimmed = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix(".") else { return trimmed }
        return String(trimmed.dropFirst())
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[qoder-cookie] \(message)")
        self.log.debug(message)
    }
}
#endif
