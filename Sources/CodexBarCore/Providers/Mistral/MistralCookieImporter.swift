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
        try self.importSessions(
            browserDetection: browserDetection,
            preferredBrowsers: preferredBrowsers,
            excludingSourceLabels: [],
            limit: 1,
            logger: logger)[0]
    }

    static func importSessions(
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser]? = nil,
        excludingSourceLabels: Set<String>,
        limit: Int? = nil,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        let log: (String) -> Void = { msg in logger?("[mistral-cookie] \(msg)") }
        let order = self.resolvedImportOrder(preferredBrowsers)
        let installedBrowsers = order.cookieImportCandidates(using: browserDetection)
        var sessions: [SessionInfo] = []

        for browserSource in installedBrowsers {
            do {
                let query = self.cookieQuery()
                let sources = try Self.cookieClient.codexBarRecords(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    guard !excludingSourceLabels.contains(source.label) else {
                        log("Skipping rejected cookie source \(source.label)")
                        continue
                    }
                    let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    if !httpCookies.isEmpty {
                        guard Self.hasSessionCookie(httpCookies) else {
                            log("Skipping \(source.label) cookies: missing ory_session_* cookie")
                            continue
                        }
                        log("Found \(httpCookies.count) Mistral cookies in \(source.label)")
                        sessions.append(SessionInfo(cookies: httpCookies, sourceLabel: source.label))
                        if sessions.count == limit {
                            return sessions
                        }
                    }
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        guard !sessions.isEmpty else { throw MistralCookieImportError.noCookies }
        return sessions
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
