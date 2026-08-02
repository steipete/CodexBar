import Foundation

#if os(macOS)
import SweetCookieKit

public enum HyperCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["hyper.charm.land"]
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.hyper]?.browserCookieOrder ?? [.chrome]

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String

        public var cookieHeader: String {
            self.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    public static func importSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let candidates = self.cookieImportOrder.cookieImportCandidates(using: browserDetection)
        for browser in candidates {
            do {
                if let session = try self.importSessions(from: browser, logger: logger).first {
                    return session
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                logger?("[hyper-cookie] \(browser.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }
        throw HyperCookieImportError.noCookies
    }

    public static func hasSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) -> Bool
    {
        (try? self.importSession(browserDetection: browserDetection, logger: logger)) != nil
    }

    private static func importSessions(
        from browser: Browser,
        logger: ((String) -> Void)?) throws -> [SessionInfo]
    {
        let query = BrowserCookieQuery(domains: self.cookieDomains)
        let sources = try self.cookieClient.codexBarRecords(
            matching: query,
            in: browser,
            logger: logger)
        let groups = Dictionary(grouping: sources, by: { $0.store.profile.id })

        return groups.values.compactMap { group in
            let records = self.mergeRecords(group)
            let cookies = BrowserCookieClient.makeHTTPCookies(records, origin: query.origin)
            guard !cookies.isEmpty else { return nil }
            let sourceLabel = group.map(\.label).min() ?? browser.displayName
            logger?("[hyper-cookie] Found \(cookies.count) cookie(s) in \(sourceLabel)")
            return SessionInfo(cookies: cookies, sourceLabel: sourceLabel)
        }
        .sorted { $0.sourceLabel < $1.sourceLabel }
    }

    private static func mergeRecords(_ sources: [BrowserCookieStoreRecords]) -> [BrowserCookieRecord] {
        let sortedSources = sources.sorted { self.priority($0.store.kind) < self.priority($1.store.kind) }
        var recordsByKey: [String: BrowserCookieRecord] = [:]
        for source in sortedSources {
            for record in source.records {
                let key = "\(record.name)|\(record.domain)|\(record.path)"
                if let current = recordsByKey[key] {
                    if self.shouldReplace(current, with: record) {
                        recordsByKey[key] = record
                    }
                } else {
                    recordsByKey[key] = record
                }
            }
        }
        return recordsByKey.values.sorted { lhs, rhs in
            (lhs.name, lhs.domain, lhs.path) < (rhs.name, rhs.domain, rhs.path)
        }
    }

    private static func priority(_ kind: BrowserCookieStoreKind) -> Int {
        switch kind {
        case .network: 0
        case .primary: 1
        case .safari: 2
        }
    }

    private static func shouldReplace(_ current: BrowserCookieRecord, with candidate: BrowserCookieRecord) -> Bool {
        switch (current.expires, candidate.expires) {
        case let (lhs?, rhs?): rhs > lhs
        case (nil, .some): true
        case (.some, nil), (nil, nil): false
        }
    }
}

enum HyperCookieImportError: LocalizedError {
    case noCookies

    var errorDescription: String? {
        "No Charm Hyper browser session found. Sign in to hyper.charm.land or configure an API key."
    }
}
#endif
