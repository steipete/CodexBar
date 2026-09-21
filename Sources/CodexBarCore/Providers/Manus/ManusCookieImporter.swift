import Foundation

#if os(macOS)
import SweetCookieKit

public enum ManusCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.provider(.manus, scope: "cookie"))
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["manus.im", "www.manus.im"]
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.manus]?.browserCookieOrder ?? Browser.defaultImportOrder
    #if DEBUG
    final class ImportSessionOverrideStore: @unchecked Sendable {
        let importSession: (BrowserDetection, ((String) -> Void)?) throws -> SessionInfo

        init(importSession: @escaping (BrowserDetection, ((String) -> Void)?) throws -> SessionInfo) {
            self.importSession = importSession
        }
    }

    final class ImportSessionsOverrideStore: @unchecked Sendable {
        let importSessions: (BrowserDetection, ((String) -> Void)?) throws -> [SessionInfo]

        init(importSessions: @escaping (BrowserDetection, ((String) -> Void)?) throws -> [SessionInfo]) {
            self.importSessions = importSessions
        }
    }

    @TaskLocal private static var taskImportSessionOverrideStore: ImportSessionOverrideStore?
    @TaskLocal private static var taskImportSessionsOverrideStore: ImportSessionsOverrideStore?

    static func withImportSessionOverrideForTesting<T>(
        _ override: ((BrowserDetection, ((String) -> Void)?) throws -> SessionInfo)?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskImportSessionOverrideStore.withValue(override.map(ImportSessionOverrideStore.init)) {
            try await operation()
        }
    }

    static func withImportSessionsOverrideForTesting<T>(
        _ override: ((BrowserDetection, ((String) -> Void)?) throws -> [SessionInfo])?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskImportSessionsOverrideStore.withValue(override.map(ImportSessionsOverrideStore.init)) {
            try await operation()
        }
    }
    #endif

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String

        public init(cookies: [HTTPCookie], sourceLabel: String) {
            self.cookies = cookies
            self.sourceLabel = sourceLabel
        }

        public var sessionToken: String? {
            ManusCookieHeader.sessionToken(from: self.cookies)
        }
    }

    public static func importSessions(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        #if DEBUG
        if let override = self.taskImportSessionsOverrideStore?.importSessions {
            return try override(browserDetection, logger)
        }
        if let override = self.taskImportSessionOverrideStore?.importSession {
            return try [override(browserDetection, logger)]
        }
        #endif

        return try BrowserCookieImportSupport.collectSessions(
            from: self.cookieImportOrder.cookieImportCandidates(using: browserDetection),
            missingError: ManusCookieImportError.noCookies,
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
            guard let token = session.sessionToken else {
                continue
            }

            log("Found \(ManusCookieHeader.sessionCookieName) cookie in \(label)")
            if !token.isEmpty {
                sessions.append(session)
            }
        }

        return sessions
    }

    public static func importSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let sessions = try self.importSessions(browserDetection: browserDetection, logger: logger)
        guard let first = sessions.first else {
            throw ManusCookieImportError.noCookies
        }
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

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[manus-cookie] \(message)")
        self.log.debug(message)
    }
}

enum ManusCookieImportError: LocalizedError {
    case noCookies

    var errorDescription: String? {
        switch self {
        case .noCookies:
            "No Manus session cookies found in browsers. Please log into manus.im."
        }
    }
}
#endif
