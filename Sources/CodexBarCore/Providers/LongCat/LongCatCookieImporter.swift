import Foundation

#if os(macOS)
import SweetCookieKit

public enum LongCatCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.provider(.longcat, scope: "cookie"))
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["longcat.chat", "www.longcat.chat"]
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.longcat]?.browserCookieOrder ?? Browser.defaultImportOrder

    public struct SessionInfo: Sendable {
        /// Full imported jar. The fetcher applies browser-equivalent URL matching
        /// before building each request header.
        public let cookies: [HTTPCookie]
        public let sourceLabel: String

        public init(cookies: [HTTPCookie], sourceLabel: String) {
            self.cookies = cookies
            self.sourceLabel = sourceLabel
        }
    }

    public static func importSessions(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        try BrowserCookieImportSupport.collectSessions(
            from: self.cookieImportOrder.cookieImportCandidates(using: browserDetection),
            missingError: LongCatCookieImportError.noCookies,
            logger: { self.emit($0, logger: logger) },
            load: { try self.importSessions(from: $0, logger: logger) })
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
            log("Found \(httpCookies.count) longcat.chat cookie(s) in \(label)")
            sessions.append(SessionInfo(cookies: httpCookies, sourceLabel: label))
        }
        return sessions
    }

    public static func importSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let sessions = try self.importSessions(browserDetection: browserDetection, logger: logger)
        guard let first = sessions.first else {
            throw LongCatCookieImportError.noCookies
        }
        return first
    }

    public static func hasSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) -> Bool
    {
        do {
            return try !self.importSessions(browserDetection: browserDetection, logger: logger).isEmpty
        } catch {
            return false
        }
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[longcat-cookie] \(message)")
        self.log.debug(message)
    }
}

enum LongCatCookieImportError: LocalizedError {
    case noCookies

    var errorDescription: String? {
        switch self {
        case .noCookies:
            "No LongCat session cookies found in browsers."
        }
    }
}
#endif
