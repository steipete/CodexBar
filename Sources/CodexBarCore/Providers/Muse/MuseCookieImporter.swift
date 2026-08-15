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
}
#endif
