import Foundation

#if os(macOS)
import SweetCookieKit

/// Imports CommandCode session cookies from installed browsers (Chrome by default).
public enum CommandCodeCookieImporter {
    private static let importSessionCacheTTL: TimeInterval = 5
    private static let importSessionCache = ExpiringValueCache<[SessionInfo]>(ttl: importSessionCacheTTL)
    private static let log = CodexBarLog.logger(LogCategories.provider(.commandcode, scope: "cookie"))
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["commandcode.ai", "www.commandcode.ai"]
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.commandcode]?.browserCookieOrder ?? Browser.defaultImportOrder

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String

        public init(cookies: [HTTPCookie], sourceLabel: String) {
            self.cookies = cookies
            self.sourceLabel = sourceLabel
        }

        public var sessionCookie: CommandCodeCookieOverride? {
            CommandCodeCookieHeader.sessionCookie(from: self.cookies)
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

        guard !sessions.isEmpty else {
            throw CommandCodeCookieImportError.noCookies
        }
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
            guard !mergedRecords.isEmpty else { continue }
            let httpCookies = BrowserCookieClient.makeHTTPCookies(mergedRecords, origin: query.origin)
            guard !httpCookies.isEmpty else { continue }

            let session = SessionInfo(cookies: httpCookies, sourceLabel: label)
            if let sessionCookie = session.sessionCookie {
                log("Found \(sessionCookie.name) cookie in \(label)")
            } else {
                let names = httpCookies.map(\.name).joined(separator: ", ")
                log("No known session name in \(label); sending all domain cookies (\(names))")
            }
            sessions.append(session)
        }
        return sessions
    }

    public static func importSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let sessions = try self.importSessions(browserDetection: browserDetection, logger: logger)
        guard let first = sessions.first else { throw CommandCodeCookieImportError.noCookies }
        return first
    }

    public static func hasSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) -> Bool
    {
        do {
            let session = try self.importSession(browserDetection: browserDetection, logger: logger)
            return !session.cookies.isEmpty
        } catch {
            return false
        }
    }

    static func invalidateImportSessionCache() {
        self.importSessionCache.invalidate()
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[commandcode-cookie] \(message)")
        self.log.debug(message)
    }

    private static func cachedImportSessions(now: Date = Date()) -> [SessionInfo]? {
        self.importSessionCache.load(now: now)
    }

    private static func storeImportSessions(_ sessions: [SessionInfo], now: Date = Date()) {
        self.importSessionCache.store(sessions, now: now)
    }
}

public enum CommandCodeCookieImportError: LocalizedError {
    case noCookies

    public var errorDescription: String? {
        switch self {
        case .noCookies:
            "No Command Code session cookies found in browsers. Sign in to commandcode.ai."
        }
    }
}
#endif
