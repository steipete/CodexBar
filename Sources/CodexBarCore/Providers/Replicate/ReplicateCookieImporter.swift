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

    static func importSessions(
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser]? = nil,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        let order = self.resolvedImportOrder(preferredBrowsers)
        var sessions: [SessionInfo] = []
        for browser in order.cookieImportCandidates(using: browserDetection) {
            do {
                let query = self.cookieQuery()
                let sources = try Self.cookieClient.codexBarRecords(matching: query, in: browser, logger: logger)
                for source in sources {
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    guard Self.hasSessionCookie(cookies) else { continue }
                    // CSRF is optional for these reads; retain every usable session candidate.
                    sessions.append(SessionInfo(cookies: cookies, sourceLabel: source.label))
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
            }
        }
        guard !sessions.isEmpty else { throw ReplicateCredentialError.missingCookie }
        return sessions
    }

    static func resolvedImportOrder(_ preferredBrowsers: [Browser]?) -> [Browser] {
        guard let preferredBrowsers, !preferredBrowsers.isEmpty else { return [.chrome] }
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
