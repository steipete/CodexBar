import Foundation

#if os(macOS)
import SweetCookieKit

public enum PerplexityCookieImporter {
    private static let importSessionCacheTTL: TimeInterval = 5
    private static let importSessionCache = ExpiringValueCache<[SessionInfo]>(ttl: importSessionCacheTTL)
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
        #if DEBUG
        if let overrideStore = self.taskImportSessionsOverrideStore {
            return try overrideStore.sessions(browserDetection: browserDetection, logger: logger)
        }
        if let overrideStore = self.taskImportSessionOverrideStore {
            return try overrideStore.sessions(browserDetection: browserDetection, logger: logger)
        }
        #endif
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
            throw PerplexityCookieImportError.noCookies
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
        let sessions = try self.importSessions(browserDetection: browserDetection, logger: logger)
        guard let first = sessions.first else {
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

    static func invalidateImportSessionCache() {
        self.importSessionCache.invalidate()
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[perplexity-cookie] \(message)")
        self.log.debug(message)
    }

    private static func cachedImportSessions(now: Date = Date()) -> [SessionInfo]? {
        self.importSessionCache.load(now: now)
    }

    private static func storeImportSessions(_ sessions: [SessionInfo], now: Date = Date()) {
        self.importSessionCache.store(sessions, now: now)
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
