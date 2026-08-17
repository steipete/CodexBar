import Foundation

#if os(macOS)
import SweetCookieKit

public enum XAICookieImporter {
    private static let importSessionCacheTTL: TimeInterval = 5
    private static let importSessionCache = ImportSessionCache(ttl: Self.importSessionCacheTTL)
    private static let log = CodexBarLog.logger(LogCategories.providers)
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["grok.com"]
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.xai]?.browserCookieOrder ?? Browser.defaultImportOrder

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

        guard !sessions.isEmpty else {
            throw ProviderFetchClassifiedError(
                kind: .missingCredential,
                message: XAIWebFetchStrategy.missingCookieMessage)
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
            guard mergedRecords.contains(where: { $0.name == "sso" || $0.name == "sso-rw" })
            else { continue }
            let httpCookies = BrowserCookieClient.makeHTTPCookies(
                mergedRecords, origin: query.origin)
            guard !httpCookies.isEmpty else { continue }
            log("Found SuperGrok session cookies in \(label)")
            sessions.append(SessionInfo(cookies: httpCookies, sourceLabel: label))
        }
        return sessions
    }

    public static func hasSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) -> Bool
    {
        (try? self.importSessions(browserDetection: browserDetection, logger: logger).isEmpty)
            == false
    }

    static func invalidateImportSessionCache() {
        self.importSessionCache.invalidate()
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[xai-cookie] \(message)")
        self.log.debug("\(message)")
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

    private static func mergeRecords(_ sources: [BrowserCookieStoreRecords])
        -> [BrowserCookieRecord]
    {
        var merged: [String: BrowserCookieRecord] = [:]
        for source in sources.sorted(by: {
            self.storePriority($0.store.kind) < self.storePriority($1.store.kind)
        }) {
            for record in source.records {
                let key = self.recordKey(record)
                if let existing = merged[key],
                   !self.shouldReplace(existing: existing, candidate: record)
                {
                    continue
                }
                merged[key] = record
            }
        }
        return Array(merged.values)
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

    private static func shouldReplace(
        existing: BrowserCookieRecord, candidate: BrowserCookieRecord) -> Bool
    {
        switch (existing.expires, candidate.expires) {
        case let (lhs?, rhs?): rhs > lhs
        case (nil, .some): true
        case (.some, nil): false
        case (nil, nil): false
        }
    }

    private final class ImportSessionCache: @unchecked Sendable {
        private let lock = NSLock()
        private let ttl: TimeInterval
        private var sessions: [SessionInfo]?
        private var storedAt: Date?

        init(ttl: TimeInterval) {
            self.ttl = ttl
        }

        func load(now: Date) -> [SessionInfo]? {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let storedAt, now.timeIntervalSince(storedAt) < self.ttl else { return nil }
            return self.sessions
        }

        func store(_ sessions: [SessionInfo], now: Date) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.sessions = sessions
            self.storedAt = now
        }

        func invalidate() {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.sessions = nil
            self.storedAt = nil
        }
    }
}
#else
public enum XAICookieImporter {
    public struct SessionInfo: Sendable {
        public let cookieHeader: String
        public let sourceLabel: String
    }

    public static func importSessions(
        browserDetection _: BrowserDetection = BrowserDetection(),
        logger _: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        throw ProviderFetchClassifiedError(
            kind: .missingCredential,
            message: XAIWebFetchStrategy.missingCookieMessage)
    }

    public static func hasSession(
        browserDetection _: BrowserDetection = BrowserDetection(),
        logger _: ((String) -> Void)? = nil) -> Bool
    {
        false
    }
}
#endif
