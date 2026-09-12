import Foundation

#if os(macOS)
import SweetCookieKit

private let minimaxCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.minimax]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum MiniMaxCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.provider(.minimax, scope: "cookie"))
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = [
        "platform.minimax.io",
        "openplatform.minimax.io",
        "minimax.io",
        "platform.minimaxi.com",
        "openplatform.minimaxi.com",
        "minimaxi.com",
    ]

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
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        var sessions: [SessionInfo] = []

        // Filter to cookie-eligible browsers to avoid unnecessary keychain prompts
        let installedBrowsers = minimaxCookieImportOrder.cookieImportCandidates(using: browserDetection)
        for browserSource in installedBrowsers {
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
            throw MiniMaxCookieImportError.noCookies
        }
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
            log("Found \(httpCookies.count) MiniMax cookies in \(label)")
            log("\(label) cookie names: \(self.cookieNames(from: httpCookies))")
            if let token = httpCookies.first(where: { $0.name == "HERTZ-SESSION" })?.value {
                let hint = token.contains(".") ? "jwt" : "opaque"
                log("\(label) HERTZ-SESSION: \(token.count) chars (\(hint))")
            }
            sessions.append(SessionInfo(cookies: httpCookies, sourceLabel: label))
        }
        return sessions
    }

    public static func importSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let sessions = try self.importSessions(browserDetection: browserDetection, logger: logger)
        guard let first = sessions.first else {
            throw MiniMaxCookieImportError.noCookies
        }
        return first
    }

    public static func hasSession(browserDetection: BrowserDetection, logger: ((String) -> Void)? = nil) -> Bool {
        do {
            return try !self.importSessions(browserDetection: browserDetection, logger: logger).isEmpty
        } catch {
            return false
        }
    }

    private static func cookieNames(from cookies: [HTTPCookie]) -> String {
        let names = Set(cookies.map { "\($0.name)@\($0.domain)" }).sorted()
        return names.joined(separator: ", ")
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[minimax-cookie] \(message)")
        self.log.debug(message)
    }
}

enum MiniMaxCookieImportError: LocalizedError {
    case noCookies

    var errorDescription: String? {
        switch self {
        case .noCookies:
            "No MiniMax session cookies found in browsers."
        }
    }
}
#endif
