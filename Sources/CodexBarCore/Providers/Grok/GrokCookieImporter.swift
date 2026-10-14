import Foundation

#if os(macOS)
import SweetCookieKit

public enum GrokCookieImporter {
    private static let importSessionCacheTTL: TimeInterval = 5
    private static let importSessionCache = ExpiringValueCache<[SessionInfo]>(ttl: importSessionCacheTTL)
    private static let log = CodexBarLog.logger(LogCategories.providers)
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["grok.com"]
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.grok]?.browserCookieOrder ?? Browser.defaultImportOrder

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
    }

    public static func importSessions(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        if let cached = self.cachedImportSessions() {
            return cached
        }

        let sessions = try Array(self.sessionCandidates(browserDetection: browserDetection, logger: logger))
        self.storeImportSessions(sessions)
        return sessions
    }

    static func sessionCandidates(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil,
        loadRecords: @escaping (Browser, BrowserCookieQuery, ((String) -> Void)?) throws
            -> [BrowserCookieStoreRecords] = { try cookieClient.codexBarRecords(matching: $1, in: $0, logger: $2) })
        throws -> AnySequence<SessionInfo>
    {
        try BrowserCookieImportSupport.collectSessions(
            from: self.cookieImportOrder.lazyCookieImportCandidates(using: browserDetection),
            missingError: GrokWebBillingError.missingCredentials,
            logger: { self.emit($0, logger: logger) },
            load: { try self.sessions(from: $0, logger: logger, loadRecords: loadRecords) })
    }

    public static func importSessions(
        from browserSource: Browser,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        try self.sessions(from: browserSource, logger: logger) {
            try self.cookieClient.codexBarRecords(matching: $1, in: $0, logger: $2)
        }
    }

    private static func sessions(
        from browserSource: Browser,
        logger: ((String) -> Void)?,
        loadRecords: (Browser, BrowserCookieQuery, ((String) -> Void)?) throws -> [BrowserCookieStoreRecords])
        throws -> [SessionInfo]
    {
        let query = BrowserCookieQuery(domains: self.cookieDomains)
        let log: (String) -> Void = { msg in self.emit(msg, logger: logger) }
        let sources = try loadRecords(browserSource, query, log)

        var sessions: [SessionInfo] = []

        for profile in BrowserCookieProfiles.merge(sources) {
            let label = profile.label
            let mergedRecords = profile.records
            guard mergedRecords.contains(where: { $0.name == "sso" || $0.name == "sso-rw" }) else { continue }
            let httpCookies = BrowserCookieClient.makeHTTPCookies(mergedRecords, origin: query.origin)
            guard !httpCookies.isEmpty else { continue }
            log("Found Grok session cookies in \(label)")
            sessions.append(SessionInfo(cookies: httpCookies, sourceLabel: label))
        }
        return sessions
    }

    public static func importSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let sessions = try self.sessionCandidates(browserDetection: browserDetection, logger: logger)
        guard let first = sessions.first(where: { _ in true }) else { throw GrokWebBillingError.missingCredentials }
        return first
    }

    public static func hasSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) -> Bool
    {
        do {
            _ = try self.importSession(browserDetection: browserDetection, logger: logger)
            return true
        } catch {
            return false
        }
    }

    static func invalidateImportSessionCache() {
        self.importSessionCache.invalidate()
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[grok-cookie] \(message)")
        self.log.debug("\(message)")
    }

    private static func cachedImportSessions(now: Date = Date()) -> [SessionInfo]? {
        self.importSessionCache.load(now: now)
    }

    private static func storeImportSessions(_ sessions: [SessionInfo], now: Date = Date()) {
        self.importSessionCache.store(sessions, now: now)
    }
}
#else
public enum GrokCookieImporter {
    public static func hasSession(
        browserDetection _: BrowserDetection = BrowserDetection(),
        logger _: ((String) -> Void)? = nil) -> Bool
    {
        false
    }
}
#endif
