import Foundation

#if os(macOS)
import SweetCookieKit

private let replicateCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.replicate]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum ReplicateCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    static let cookieDomains = ReplicateBillingEndpoints.cookieDomains

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

        public var csrfToken: String? {
            self.cookies.first { $0.name == "csrftoken" }?.value
        }
    }

    static func hasSessionCookie(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { $0.name == "sessionid" }
    }

    private static func hasCSRFToken(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { $0.name == "csrftoken" }
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
        let log: (String) -> Void = { msg in logger?("[replicate-cookie] \(msg)") }
        let order = self.resolvedImportOrder(preferredBrowsers)
        let installedBrowsers = order.cookieImportCandidates(using: browserDetection)
        var sessions: [SessionInfo] = []
        var sessionidOnlyFallback: SessionInfo?

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
                            log("Skipping \(source.label) cookies: missing sessionid cookie")
                            continue
                        }
                        log("Found \(httpCookies.count) Replicate cookies in \(source.label)")
                        let session = SessionInfo(cookies: httpCookies, sourceLabel: source.label)
                        if Self.hasCSRFToken(httpCookies) {
                            sessions.append(session)
                            if sessions.count == limit {
                                return sessions
                            }
                        } else if sessionidOnlyFallback == nil {
                            sessionidOnlyFallback = session
                        }
                    }
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        if sessions.isEmpty, let sessionidOnlyFallback {
            sessions.append(sessionidOnlyFallback)
        }

        guard !sessions.isEmpty else { throw ReplicateCookieImportError.noCookies }
        if let limit {
            return Array(sessions.prefix(limit))
        }
        return sessions
    }

    static func resolvedImportOrder(_ preferredBrowsers: [Browser]?) -> [Browser] {
        guard let preferredBrowsers, !preferredBrowsers.isEmpty else {
            return replicateCookieImportOrder
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

enum ReplicateCookieImportError: LocalizedError {
    case noCookies

    var errorDescription: String? {
        switch self {
        case .noCookies:
            "No Replicate session cookies found in browsers."
        }
    }
}
#endif
