import Foundation

#if os(macOS)
import SweetCookieKit

public enum VeniceCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.provider(.venice, scope: "cookie"))
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["venice.ai"]
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.venice]?.browserCookieOrder ?? Browser.defaultImportOrder

    public static func importSessions(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> [VeniceResolvedSession]
    {
        try Array(self.sessionCandidates(browserDetection: browserDetection, logger: logger))
    }

    static func sessionCandidates(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil,
        loadRecords: @escaping (Browser, BrowserCookieQuery, ((String) -> Void)?) throws
            -> [BrowserCookieStoreRecords] = { try cookieClient.codexBarRecords(matching: $1, in: $0, logger: $2) })
        throws -> AnySequence<VeniceResolvedSession>
    {
        try BrowserCookieImportSupport.collectSessions(
            from: self.cookieImportOrder.lazyCookieImportCandidates(using: browserDetection),
            missingError: VeniceUsageError.missingCredentials,
            logger: { self.emit($0, logger: logger) },
            load: { try self.sessions(from: $0, logger: logger, loadRecords: loadRecords) })
    }

    public static func importSessions(
        from browserSource: Browser,
        logger: ((String) -> Void)? = nil) throws -> [VeniceResolvedSession]
    {
        try self.sessions(from: browserSource, logger: logger) {
            try self.cookieClient.codexBarRecords(matching: $1, in: $0, logger: $2)
        }
    }

    private static func sessions(
        from browserSource: Browser,
        logger: ((String) -> Void)?,
        loadRecords: (Browser, BrowserCookieQuery, ((String) -> Void)?) throws -> [BrowserCookieStoreRecords])
        throws -> [VeniceResolvedSession]
    {
        let query = BrowserCookieQuery(domains: self.cookieDomains, domainMatch: .exact)
        let log: (String) -> Void = { msg in self.emit(msg, logger: logger) }
        let sources = try loadRecords(browserSource, query, log)

        var sessions: [VeniceResolvedSession] = []
        for profile in BrowserCookieProfiles.merge(sources) {
            let label = profile.label
            let mergedRecords = profile.records
            let sessionRecords = mergedRecords.filter { VeniceCookieHeader.isSessionCookieName($0.name) }
            guard !sessionRecords.isEmpty else { continue }
            let httpCookies = BrowserCookieClient.makeHTTPCookies(sessionRecords, origin: query.origin)
            guard let cookieHeader = VeniceCookieHeader.header(from: httpCookies) else { continue }
            let names = Set(httpCookies.map(\.name)).sorted().joined(separator: ", ")
            log("Found Venice session cookie (\(names)) in \(label)")
            sessions.append(VeniceResolvedSession(cookieHeader: cookieHeader, sourceLabel: label))
        }
        return sessions
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[venice-cookie] \(message)")
        self.log.debug("\(message)")
    }
}
#endif
