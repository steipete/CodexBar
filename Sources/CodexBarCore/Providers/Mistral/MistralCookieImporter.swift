import Foundation

#if os(macOS)
import SweetCookieKit

private let mistralCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.mistral]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum MistralCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    static let cookieDomains = ["mistral.ai", "admin.mistral.ai", "auth.mistral.ai", "console.mistral.ai"]

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String

        public init(cookies: [HTTPCookie], sourceLabel: String) {
            self.cookies = cookies
            self.sourceLabel = sourceLabel
        }

        public var cookieHeader: String {
            self.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }

        /// Extracts the CSRF token from the `csrftoken` cookie for the `X-CSRFTOKEN` header.
        public var csrfToken: String? {
            self.cookies.first { $0.name == "csrftoken" }?.value
        }
    }

    /// Returns `true` if any cookie name starts with `ory_session_` (the Ory Kratos session cookie).
    private static func hasSessionCookie(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { $0.name.hasPrefix("ory_session_") }
    }

    public static func importSession(
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser]? = nil,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let candidates = try self.sessionCandidates(
            browserDetection: browserDetection, preferredBrowsers: preferredBrowsers, logger: logger)
        guard let first = candidates.first(where: { _ in true }) else { throw MistralCookieImportError.noCookies }
        return first
    }

    static func sessionCandidates(
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser]? = nil,
        excludingSourceLabels: Set<String> = [],
        logger: ((String) -> Void)? = nil,
        loadRecords: @escaping (Browser, BrowserCookieQuery, ((String) -> Void)?) throws
            -> [BrowserCookieStoreRecords] = { try cookieClient.codexBarRecords(matching: $1, in: $0, logger: $2) })
        throws -> AnySequence<SessionInfo>
    {
        let log: (String) -> Void = { logger?("[mistral-cookie] \($0)") }
        return try BrowserCookieImportSupport.collectSessions(
            from: self.resolvedImportOrder(preferredBrowsers).lazyCookieImportCandidates(using: browserDetection),
            missingError: MistralCookieImportError.noCookies,
            logger: log,
            load: { browser in
                let query = self.cookieQuery()
                return try loadRecords(browser, query, log).compactMap { source in
                    guard !excludingSourceLabels.contains(source.label) else {
                        log("Skipping rejected cookie source \(source.label)")
                        return nil
                    }
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    guard Self.hasSessionCookie(cookies) else {
                        log("Skipping \(source.label) cookies: missing ory_session_* cookie")
                        return nil
                    }
                    log("Found \(cookies.count) Mistral cookies in \(source.label)")
                    return SessionInfo(cookies: cookies, sourceLabel: source.label)
                }
            })
    }

    static func resolvedImportOrder(_ preferredBrowsers: [Browser]?) -> [Browser] {
        guard let preferredBrowsers, !preferredBrowsers.isEmpty else {
            return mistralCookieImportOrder
        }
        return preferredBrowsers
    }

    static func cookieQuery(referenceDate: Date = Date()) -> BrowserCookieQuery {
        BrowserCookieQuery(
            domains: self.cookieDomains,
            domainMatch: .exact,
            includeExpired: false,
            referenceDate: referenceDate)
    }

    public static func hasSession(
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser]? = nil,
        logger: ((String) -> Void)? = nil) -> Bool
    {
        do {
            _ = try self.importSession(
                browserDetection: browserDetection,
                preferredBrowsers: preferredBrowsers,
                logger: logger)
            return true
        } catch {
            return false
        }
    }
}

enum MistralCookieImportError: LocalizedError {
    case noCookies

    var errorDescription: String? {
        switch self {
        case .noCookies:
            "No Mistral session cookies found in browsers."
        }
    }
}
#endif
