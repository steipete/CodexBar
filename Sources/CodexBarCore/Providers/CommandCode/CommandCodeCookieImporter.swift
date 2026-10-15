import Foundation

#if os(macOS)
import SweetCookieKit

/// Imports CommandCode session cookies from installed browsers (Chrome by default).
public enum CommandCodeCookieImporter {
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
        try Array(self.sessionCandidates(browserDetection: browserDetection, logger: logger))
    }

    static func sessionCandidates(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> AnySequence<SessionInfo>
    {
        try BrowserCookieImportSupport.collectSessions(
            from: self.cookieImportOrder.lazyCookieImportCandidates(using: browserDetection),
            missingError: CommandCodeCookieImportError.noCookies,
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
        let sessions = try self.sessionCandidates(browserDetection: browserDetection, logger: logger)
        guard let first = sessions.first(where: { _ in true }) else { throw CommandCodeCookieImportError.noCookies }
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

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[commandcode-cookie] \(message)")
        self.log.debug(message)
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
