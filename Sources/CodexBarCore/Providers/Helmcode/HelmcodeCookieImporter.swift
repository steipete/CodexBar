import Foundation

#if os(macOS)
import SweetCookieKit

public enum HelmcodeCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.provider(.helmcode, scope: "cookie"))
    private static let cookieClient = BrowserCookieClient()
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
        deployment: HelmcodeDeployment = .helmcode,
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        var sessions: [SessionInfo] = []
        let candidates = self.cookieImportOrder.cookieImportCandidates(using: browserDetection)
        for browserSource in candidates {
            do {
                try sessions.append(contentsOf: self.importSessions(
                    from: browserSource,
                    deployment: deployment,
                    logger: logger))
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                self.emit(
                    "\(browserSource.displayName) cookie import failed: \(error.localizedDescription)",
                    logger: logger)
            }
        }

        guard !sessions.isEmpty else { throw HelmcodeUsageError.missingCookies(deployment) }
        return sessions
    }

    public static func importSessions(
        from browserSource: Browser,
        deployment: HelmcodeDeployment = .helmcode,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        let query = BrowserCookieQuery(domains: deployment.cookieDomains)
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
            let cookies = Self.makeCookies(from: records)
            guard HelmcodeCookieHeader.header(from: cookies, for: deployment.quotaURL) != nil else {
                return nil
            }
            let label = self.mergedLabel(for: group)
            log("Found \(deployment.displayName) dashboard cookies in \(label)")
            return SessionInfo(cookies: cookies, sourceLabel: label)
        }
    }

    /// Builds request cookies while preserving the browser's domain scope. SweetCookieKit normalizes
    /// record domains without the leading dot, so domain-scoped cookies must re-add it or the
    /// subdomain header match in `HelmcodeCookieHeader` would drop them.
    static func makeCookies(from records: [BrowserCookieRecord]) -> [HTTPCookie] {
        records.compactMap { record in
            guard !record.domain.isEmpty else { return nil }
            var domain = record.domain
            if record.scope == .domain {
                domain = "." + domain
            }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: domain,
                .path: record.path,
                .name: record.name,
                .value: record.value,
                .secure: record.isSecure,
            ]
            if let originURL = URL(string: "https://\(record.domain)") {
                properties[.originURL] = originURL
            }
            if record.isHTTPOnly {
                properties[.init("HttpOnly")] = "TRUE"
            }
            if let expires = record.expires {
                properties[.expires] = expires
            }
            return HTTPCookie(properties: properties)
        }
    }

    public static func hasSession(
        deployment: HelmcodeDeployment = .helmcode,
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) -> Bool
    {
        (try? !self.importSessions(
            deployment: deployment,
            browserDetection: browserDetection,
            logger: logger).isEmpty) ?? false
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
