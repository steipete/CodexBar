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

        let sessions = try BrowserCookieImportSupport.collectSessions(
            from: self.cookieImportOrder.cookieImportCandidates(using: browserDetection),
            missingError: CommandCodeCookieImportError.noCookies,
            logger: { self.emit($0, logger: logger) },
            load: { try self.importSessions(from: $0, logger: logger) })
        self.storeImportSessions(sessions)
        return sessions
    }

    public static func importSessions(
        from browserSource: Browser,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        let log: (String) -> Void = { message in self.emit(message, logger: logger) }
        let profiles = try BrowserCookieImportSupport.loadProfiles(
            from: browserSource,
            domains: self.cookieDomains,
            client: self.cookieClient,
            logger: log)
        var sessions: [SessionInfo] = []
        for (label, httpCookies) in profiles {
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
