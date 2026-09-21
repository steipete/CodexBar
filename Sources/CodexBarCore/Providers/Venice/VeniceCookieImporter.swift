import Foundation

#if os(macOS)
import SweetCookieKit

public enum VeniceCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.provider(.venice, scope: "cookie"))
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["venice.ai"]
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.venice]?.browserCookieOrder ?? [.chrome]

    public struct SessionInfo: Sendable {
        public let cookieHeader: String
        public let sourceLabel: String

        public init(cookieHeader: String, sourceLabel: String) {
            self.cookieHeader = cookieHeader
            self.sourceLabel = sourceLabel
        }
    }

    public static func importSessions(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        try BrowserCookieImportSupport.collectSessions(
            from: self.cookieImportOrder.cookieImportCandidates(using: browserDetection),
            missingError: VeniceUsageError.missingCredentials,
            logger: { self.emit($0, logger: logger) },
            load: { try self.importSessions(from: $0, logger: logger) })
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
            let sessionRecords = mergedRecords.filter { VeniceCookieHeader.isSessionCookieName($0.name) }
            guard !sessionRecords.isEmpty else { continue }
            let httpCookies = BrowserCookieClient.makeHTTPCookies(sessionRecords, origin: query.origin)
            guard let cookieHeader = VeniceCookieHeader.header(from: httpCookies) else { continue }
            let names = Set(httpCookies.map(\.name)).sorted().joined(separator: ", ")
            log("Found Venice session cookie (\(names)) in \(label)")
            sessions.append(SessionInfo(cookieHeader: cookieHeader, sourceLabel: label))
        }
        return sessions
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[venice-cookie] \(message)")
        self.log.debug("\(message)")
    }
}
#endif
