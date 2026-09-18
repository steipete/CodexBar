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

        var sessions: [SessionInfo] = []
        let candidates = self.cookieImportOrder.cookieImportCandidates(using: browserDetection)
        for browserSource in candidates {
            do {
                let perSource = try self.importSessions(from: browserSource, logger: logger)
                sessions.append(contentsOf: perSource)
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                self.emit(
                    "\(browserSource.displayName) cookie import failed: \(error.localizedDescription)",
                    logger: logger)
            }
        }

        guard !sessions.isEmpty else { throw GrokWebBillingError.missingCredentials }
        self.storeImportSessions(sessions)
        return sessions
    }

    public static func importSessions(
        from browserSource: Browser,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        let query = BrowserCookieQuery(domains: self.cookieDomains)
        let log: (String) -> Void = { msg in self.emit(msg, logger: logger) }
        let sources = try Self.cookieClient.codexBarRecords(
            matching: query,
            in: browserSource,
            logger: log)

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
        let sessions = try self.importSessions(browserDetection: browserDetection, logger: logger)
        guard let first = sessions.first else { throw GrokWebBillingError.missingCredentials }
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
