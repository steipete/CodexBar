import Foundation

#if os(macOS)
import SweetCookieKit

public enum ReplicateCookieImporter {
    private static let cookieClient = BrowserCookieClient()

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String

        public var cookieHeader: String {
            self.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    static func hasSessionCookie(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { $0.name == "sessionid" && !$0.value.isEmpty }
    }

    static func sessionCandidates(
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser]? = nil,
        logger: ((String) -> Void)? = nil,
        loadRecords: @escaping (Browser, BrowserCookieQuery, ((String) -> Void)?) throws
            -> [BrowserCookieStoreRecords] = { try cookieClient.codexBarRecords(matching: $1, in: $0, logger: $2) })
        throws -> AnySequence<SessionInfo>
    {
        try BrowserCookieImportSupport.collectSessions(
            from: self.resolvedImportOrder(preferredBrowsers).lazyCookieImportCandidates(using: browserDetection),
            missingError: ReplicateCredentialError.missingCookie,
            logger: { logger?($0) },
            load: { browser in
                let query = self.cookieQuery()
                return try loadRecords(browser, query, logger).compactMap { source in
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    guard Self.hasSessionCookie(cookies) else { return nil }
                    // CSRF is optional for these reads; retain every usable session candidate.
                    return SessionInfo(cookies: cookies, sourceLabel: source.label)
                }
            })
    }

    static func resolvedImportOrder(_ preferredBrowsers: [Browser]?) -> [Browser] {
        guard let preferredBrowsers, !preferredBrowsers.isEmpty else { return Browser.defaultImportOrder }
        return preferredBrowsers
    }

    static func cookieQuery(referenceDate: Date = Date()) -> BrowserCookieQuery {
        BrowserCookieQuery(
            domains: ["replicate.com"],
            domainMatch: .exact,
            includeExpired: false,
            referenceDate: referenceDate)
    }
}
#endif
