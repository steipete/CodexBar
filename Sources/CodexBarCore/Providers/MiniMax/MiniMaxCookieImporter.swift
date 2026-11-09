import Foundation

#if os(macOS)
import SweetCookieKit

private let minimaxCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.minimax]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum MiniMaxCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.provider(.minimax, scope: "cookie"))
    private static let cookieClient = BrowserCookieClient()
    static var cookieQuery: BrowserCookieQuery {
        self.cookieQuery(for: nil)
    }

    private static func cookieQuery(for region: MiniMaxAPIRegion?) -> BrowserCookieQuery {
        let domains = [
            "platform.minimax.io",
            "openplatform.minimax.io",
            "account.minimax.io",
            "www.minimax.io",
            "minimax.io",
            "platform.minimax.cn",
            "account.minimax.cn",
            "www.minimax.cn",
            "minimax.cn",
            "platform.minimaxi.com",
            "openplatform.minimaxi.com",
            "account.minimaxi.com",
            "www.minimaxi.com",
            "minimaxi.com",
        ]
        let filtered = domains.filter { domain in
            switch region {
            case .global: domain.hasSuffix("minimax.io")
            case .chinaMainland: domain.hasSuffix("minimax.cn") || domain.hasSuffix("minimaxi.com")
            case nil: true
            }
        }
        return BrowserCookieQuery(domains: filtered, domainMatch: .exact)
    }

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String
        private let requestCookies: [MiniMaxBrowserCookie]

        public init(cookies: [HTTPCookie], sourceLabel: String) {
            self.cookies = cookies
            self.sourceLabel = sourceLabel
            self.requestCookies = cookies.map {
                MiniMaxBrowserCookie(
                    domain: $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                    includesSubdomains: $0.domain.hasPrefix("."),
                    path: $0.path,
                    name: $0.name,
                    value: $0.value,
                    expires: $0.expiresDate,
                    isSecure: $0.isSecure)
            }
        }

        init(records: [BrowserCookieRecord], sourceLabel: String) {
            self.cookies = BrowserCookieClient.makeHTTPCookies(records)
            self.sourceLabel = sourceLabel
            // HTTPCookie conversion loses the browser's host-only flag; retain the original record scope.
            self.requestCookies = records.map {
                MiniMaxBrowserCookie(
                    domain: $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                    includesSubdomains: $0.scope == .domain,
                    path: $0.path,
                    name: $0.name,
                    value: $0.value,
                    expires: $0.expires,
                    isSecure: $0.isSecure)
            }
        }

        public var cookieHeader: String {
            self.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }

        func webSessions(
            for region: MiniMaxAPIRegion,
            environment: [String: String] = [:]) -> [MiniMaxWebSession]
        {
            MiniMaxWebSessionDomain.candidates(for: region).compactMap { domain in
                let urls = domain.cookieURLs(for: region, environment: environment)
                let hosts = urls.compactMap(\.host) + domain.storageOrigins.compactMap { URL(string: $0)?.host }
                let cookies = self.requestCookies.filter {
                    let cookie = $0
                    return (cookie.domain == domain.rootDomain || cookie.domain.hasSuffix(".\(domain.rootDomain)")) &&
                        hosts.contains { host in
                            host == cookie.domain || (cookie.includesSubdomains && host.hasSuffix(".\(cookie.domain)"))
                        }
                }
                guard let header = urls.lazy.compactMap({
                    MiniMaxWebSession.cookieHeader(from: cookies, for: $0)
                }).first else { return nil }
                return MiniMaxWebSession(
                    cookieHeader: header,
                    sourceLabel: self.sourceLabel,
                    domain: domain,
                    cookies: cookies)
            }
        }
    }

    public static func importSessions(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        try Array(self.sessionCandidates(browserDetection: browserDetection, logger: logger))
    }

    static func sessionCandidates(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> AnySequence<SessionInfo>
    {
        try BrowserCookieImportSupport.collectSessions(
            from: minimaxCookieImportOrder.lazyCookieImportCandidates(using: browserDetection),
            missingError: MiniMaxCookieImportError.noCookies,
            logger: { self.emit($0, logger: logger) },
            load: { try self.importSessions(from: $0, region: nil, logger: logger) })
    }

    static func webSessionCandidates(
        browserDetection: BrowserDetection,
        region: MiniMaxAPIRegion,
        environment: [String: String] = [:],
        logger: ((String) -> Void)? = nil) throws -> AnySequence<MiniMaxWebSession>
    {
        try BrowserCookieImportSupport.collectSessions(
            from: minimaxCookieImportOrder.lazyCookieImportCandidates(using: browserDetection),
            missingError: MiniMaxCookieImportError.noCookies,
            logger: { self.emit($0, logger: logger) },
            load: { browser in
                try self.importSessions(from: browser, region: region, logger: logger)
                    .flatMap { $0.webSessions(for: region, environment: environment) }
            })
    }

    public static func importSessions(
        from browserSource: Browser,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        try self.importSessions(from: browserSource, region: nil, logger: logger)
    }

    private static func importSessions(
        from browserSource: Browser,
        region: MiniMaxAPIRegion?,
        logger: ((String) -> Void)?) throws -> [SessionInfo]
    {
        let log: (String) -> Void = { message in self.emit(message, logger: logger) }
        let query = self.cookieQuery(for: region)
        let records = try self.cookieClient.codexBarRecords(matching: query, in: browserSource, logger: log)
        let profiles = BrowserCookieProfiles.merge(records)
        var sessions: [SessionInfo] = []
        for profile in profiles {
            let session = SessionInfo(records: profile.records, sourceLabel: profile.label)
            let httpCookies = session.cookies
            guard !httpCookies.isEmpty else { continue }
            let label = profile.label
            log("Found \(httpCookies.count) MiniMax cookies in \(label)")
            log("\(label) cookie names: \(self.cookieNames(from: httpCookies))")
            if let token = httpCookies.first(where: { $0.name == "HERTZ-SESSION" })?.value {
                let hint = token.contains(".") ? "jwt" : "opaque"
                log("\(label) HERTZ-SESSION: \(token.count) chars (\(hint))")
            }
            sessions.append(session)
        }
        return sessions
    }

    public static func importSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let sessions = try self.sessionCandidates(browserDetection: browserDetection, logger: logger)
        guard let first = sessions.first(where: { _ in true }) else {
            throw MiniMaxCookieImportError.noCookies
        }
        return first
    }

    public static func hasSession(
        browserDetection: BrowserDetection,
        region: MiniMaxAPIRegion? = nil,
        environment: [String: String] = [:],
        logger: ((String) -> Void)? = nil) -> Bool
    {
        do {
            if let region {
                return try self.webSessionCandidates(
                    browserDetection: browserDetection,
                    region: region,
                    environment: environment,
                    logger: logger).contains(where: { _ in true })
            }
            return try self.sessionCandidates(browserDetection: browserDetection, logger: logger)
                .contains(where: { _ in true })
        } catch {
            return false
        }
    }

    private static func cookieNames(from cookies: [HTTPCookie]) -> String {
        let names = Set(cookies.map { "\($0.name)@\($0.domain)" }).sorted()
        return names.joined(separator: ", ")
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[minimax-cookie] \(message)")
        self.log.debug(message)
    }
}

enum MiniMaxCookieImportError: LocalizedError {
    case noCookies

    var errorDescription: String? {
        switch self {
        case .noCookies:
            "No MiniMax session cookies found in browsers."
        }
    }
}
#endif
