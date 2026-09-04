import Foundation

#if os(macOS)
import SweetCookieKit

public enum HelmcodeCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.provider(.helmcode, scope: "cookie"))
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["cloud-api.helmcode.com", "cloud.helmcode.com", "helmcode.com"]
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.helmcode]?.browserCookieOrder ?? Browser.defaultImportOrder

    public struct SessionInfo: Sendable {
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
        var sessions: [SessionInfo] = []
        let candidates = self.cookieImportOrder.cookieImportCandidates(using: browserDetection)
        for browserSource in candidates {
            do {
                try sessions.append(contentsOf: self.importSessions(from: browserSource, logger: logger))
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                self.emit(
                    "\(browserSource.displayName) cookie import failed: \(error.localizedDescription)",
                    logger: logger)
            }
        }

        guard !sessions.isEmpty else { throw HelmcodeUsageError.missingCookies }
        return sessions
    }

    public static func importSessions(
        from browserSource: Browser,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        let query = BrowserCookieQuery(domains: self.cookieDomains)
        let log: (String) -> Void = { message in self.emit(message, logger: logger) }
        let sources = try self.cookieClient.codexBarRecords(
            matching: query,
            in: browserSource,
            logger: log)

        let grouped = Dictionary(grouping: sources, by: { $0.store.profile.id })
        let groups = grouped.values.sorted { self.mergedLabel(for: $0) < self.mergedLabel(for: $1) }
        return groups.compactMap { group in
            guard !group.isEmpty else { return nil }
            let records = self.mergeRecords(group)
            let cookies = BrowserCookieClient.makeHTTPCookies(records, origin: query.origin)
            guard HelmcodeCookieHeader.header(from: cookies, for: HelmcodeUsageFetcher.quotaURL) != nil else {
                return nil
            }
            let label = self.mergedLabel(for: group)
            log("Found Helmcode dashboard cookies in \(label)")
            return SessionInfo(cookies: cookies, sourceLabel: label)
        }
    }

    public static func hasSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) -> Bool
    {
        (try? !self.importSessions(browserDetection: browserDetection, logger: logger).isEmpty) ?? false
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[helmcode-cookie] \(message)")
        self.log.debug(message)
    }

    private static func mergedLabel(for sources: [BrowserCookieStoreRecords]) -> String {
        guard let base = sources.map(\.label).min() else { return "Unknown" }
        return base.hasSuffix(" (Network)") ? String(base.dropLast(" (Network)".count)) : base
    }

    private static func mergeRecords(_ sources: [BrowserCookieStoreRecords]) -> [BrowserCookieRecord] {
        let sortedSources = sources.sorted { self.storePriority($0.store.kind) < self.storePriority($1.store.kind) }
        var mergedByKey: [String: BrowserCookieRecord] = [:]
        for source in sortedSources {
            for record in source.records {
                let key = "\(record.name)|\(record.domain)|\(record.path)"
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

    private static func shouldReplace(existing: BrowserCookieRecord, candidate: BrowserCookieRecord) -> Bool {
        switch (existing.expires, candidate.expires) {
        case let (lhs?, rhs?): rhs > lhs
        case (nil, .some): true
        case (.some, nil), (nil, nil): false
        }
    }
}
#endif
