import Foundation

#if os(macOS)
import SweetCookieKit

public enum PerplexityCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.provider(.perplexity, scope: "cookie"))
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["www.perplexity.ai", "perplexity.ai"]
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.perplexity]?.browserCookieOrder ?? Browser.defaultImportOrder
    #if DEBUG
    final class ImportSessionOverrideStore: @unchecked Sendable {
        let importSession: (BrowserDetection, ((String) -> Void)?) throws -> SessionInfo
        private let lock = NSLock()
        private var cachedSessions: [SessionInfo]?

        init(importSession: @escaping (BrowserDetection, ((String) -> Void)?) throws -> SessionInfo) {
            self.importSession = importSession
        }

        func sessions(
            browserDetection: BrowserDetection,
            logger: ((String) -> Void)?) throws -> [SessionInfo]
        {
            try self.lock.withLock {
                if let cachedSessions = self.cachedSessions {
                    return cachedSessions
                }
                let sessions = try [self.importSession(browserDetection, logger)]
                self.cachedSessions = sessions
                return sessions
            }
        }
    }

    final class ImportSessionsOverrideStore: @unchecked Sendable {
        let importSessions: (BrowserDetection, ((String) -> Void)?) throws -> [SessionInfo]
        private let lock = NSLock()
        private var cachedSessions: [SessionInfo]?

        init(importSessions: @escaping (BrowserDetection, ((String) -> Void)?) throws -> [SessionInfo]) {
            self.importSessions = importSessions
        }

        func sessions(
            browserDetection: BrowserDetection,
            logger: ((String) -> Void)?) throws -> [SessionInfo]
        {
            try self.lock.withLock {
                if let cachedSessions = self.cachedSessions {
                    return cachedSessions
                }
                let sessions = try self.importSessions(browserDetection, logger)
                self.cachedSessions = sessions
                return sessions
            }
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

        public var sessionCookie: PerplexityCookieOverride? {
            PerplexityCookieHeader.sessionCookie(from: self.cookies)
        }

        public var sessionToken: String? {
            self.sessionCookie?.token
        }
    }

    public static func importSessions(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        try Array(self.sessionCandidates(browserDetection: browserDetection, logger: logger))
    }

    private static func sessionCandidates(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)?) throws -> AnySequence<SessionInfo>
    {
        #if DEBUG
        if let overrideStore = self.taskImportSessionsOverrideStore {
            return try AnySequence(overrideStore.sessions(browserDetection: browserDetection, logger: logger))
        }
        if let overrideStore = self.taskImportSessionOverrideStore {
            return try AnySequence(overrideStore.sessions(browserDetection: browserDetection, logger: logger))
        }
        #endif
        return try BrowserCookieImportSupport.collectSessions(
            from: self.cookieImportOrder.lazyCookieImportCandidates(using: browserDetection),
            missingError: PerplexityCookieImportError.noCookies,
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
            guard let sessionCookie = session.sessionCookie else {
                continue
            }

            log("Found \(sessionCookie.name) cookie in \(label)")
            sessions.append(session)
        }
        return sessions
    }

    public static func importSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let sessions = try self.sessionCandidates(browserDetection: browserDetection, logger: logger)
        guard let first = sessions.first(where: { _ in true }) else {
            throw PerplexityCookieImportError.noCookies
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
        logger?("[perplexity-cookie] \(message)")
        self.log.debug(message)
    }
}

enum PerplexityCookieImportError: LocalizedError {
    case noCookies

    var errorDescription: String? {
        switch self {
        case .noCookies:
            "No Perplexity session cookies found in browsers. Please log into perplexity.ai."
        }
    }
}
#endif
