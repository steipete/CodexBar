import Foundation

#if os(macOS)
import SweetCookieKit

public enum PerplexityCookieImporter {
    private static let importSessionCacheTTL: TimeInterval = 5
    private static let importSessionCache = ImportSessionCache(ttl: importSessionCacheTTL)
    private static let log = CodexBarLog.logger(LogCategories.perplexityCookie)
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["www.perplexity.ai", "perplexity.ai"]
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.perplexity]?.browserCookieOrder ?? Browser.defaultImportOrder
    nonisolated(unsafe) static var importSessionOverrideForTesting:
        ((BrowserDetection, ((String) -> Void)?) throws -> SessionInfo)?
    nonisolated(unsafe) static var importSessionsOverrideForTesting:
        ((BrowserDetection, ((String) -> Void)?) throws -> [SessionInfo])?

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
        if let cached = self.cachedImportSessions() {
            return cached
        }
        if let override = self.importSessionsOverrideForTesting {
            let sessions = try override(browserDetection, logger)
            self.storeImportSessions(sessions)
            return sessions
        }
        if let override = self.importSessionOverrideForTesting {
            let session = try override(browserDetection, logger)
            let sessions = [session]
            self.storeImportSessions(sessions)
            return sessions
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
        let grouped = Dictionary(grouping: sources, by: { $0.store.profile.id })
        let sortedGroups = grouped.values.sorted { lhs, rhs in
            self.mergedLabel(for: lhs) < self.mergedLabel(for: rhs)
        }

        for group in sortedGroups where !group.isEmpty {
            let label = self.mergedLabel(for: group)
            let mergedRecords = self.mergeRecords(group)
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

    private static func mergedLabel(for sources: [BrowserCookieStoreRecords]) -> String {
        guard let base = sources.map(\.label).min() else { return "Unknown" }
        if base.hasSuffix(" (Network)") {
            return String(base.dropLast(" (Network)".count))
        }
        return base
    }

    private static func mergeRecords(_ sources: [BrowserCookieStoreRecords]) -> [BrowserCookieRecord] {
        let sortedSources = sources.sorted { lhs, rhs in
            self.storePriority(lhs.store.kind) < self.storePriority(rhs.store.kind)
        }
        var mergedByKey: [String: BrowserCookieRecord] = [:]
        for source in sortedSources {
            for record in source.records {
                let key = self.recordKey(record)
                if let existing = mergedByKey[key] {
                    if self.shouldReplace(existing: existing, candidate: record) {
                        mergedByKey[key] = record
                    }
                } else {
                    mergedByKey[key] = record
                }
            }
        }
        return Array(mergedByKey.values)
    }

    private static func storePriority(_ kind: BrowserCookieStoreKind) -> Int {
        switch kind {
        case .network: 0
        case .primary: 1
        case .safari: 2
        }
    }

    private static func recordKey(_ record: BrowserCookieRecord) -> String {
        "\(record.name)|\(record.domain)|\(record.path)"
    }

    private static func shouldReplace(existing: BrowserCookieRecord, candidate: BrowserCookieRecord) -> Bool {
        switch (existing.expires, candidate.expires) {
        case let (lhs?, rhs?): rhs > lhs
        case (nil, .some): true
        case (.some, nil): false
        case (nil, nil): false
        }
    }

    private final class ImportSessionCache: @unchecked Sendable {
        private let ttl: TimeInterval
        private let lock = NSLock()
        private var entry: (sessions: [SessionInfo], expiresAt: Date)?

        init(ttl: TimeInterval) {
            self.ttl = ttl
        }

        func load(now: Date) -> [SessionInfo]? {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let entry = self.entry else { return nil }
            guard entry.expiresAt > now else {
                self.entry = nil
                return nil
            }
            return entry.sessions
        }

        func store(_ sessions: [SessionInfo], now: Date) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.entry = (sessions: sessions, expiresAt: now.addingTimeInterval(self.ttl))
        }

        func invalidate() {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.entry = nil
        }
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
