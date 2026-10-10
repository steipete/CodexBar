import Foundation

#if os(macOS)
import SweetCookieKit

public enum KimiCookieImporter {
    public static func desktopAuthToken(region: KimiRegion = .china) -> String? {
        #if CODEXBAR_KIMI_DESKTOP_CANDIDATE
        return KimiDesktopSessionDiscovery.resolveNativeCandidate(region: region) {
            KimiDesktopSessionDiscovery.candidate.accessToken(
                settings: .init(cookieSource: .auto, manualCookieHeader: nil, region: region),
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        } legacyCookie: {
            KimiDesktopAuthToken.load(region: region)
        }
        #else
        return KimiDesktopAuthToken.load(region: region)
        #endif
    }

    private static let log = CodexBarLog.logger(LogCategories.provider(.kimi, scope: "cookie"))
    private static let cookieClient = BrowserCookieClient()
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.kimi]?.browserCookieOrder ?? Browser.defaultImportOrder

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String

        public init(cookies: [HTTPCookie], sourceLabel: String) {
            self.cookies = cookies
            self.sourceLabel = sourceLabel
        }

        public var authToken: String? {
            self.cookies.first(where: { $0.name == "kimi-auth" })?.value
        }
    }

    public static func importSessions(
        region: KimiRegion = .china,
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        var sessions: [SessionInfo] = []
        let candidates = self.cookieImportOrder.cookieImportCandidates(using: browserDetection)
        for browserSource in candidates {
            do {
                let perSource = try self.importSessions(from: browserSource, region: region, logger: logger)
                sessions.append(contentsOf: perSource)
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                self.emit(
                    "\(browserSource.displayName) cookie import failed: \(error.localizedDescription)",
                    logger: logger)
            }
        }

        guard !sessions.isEmpty else {
            throw KimiCookieImportError.noCookies
        }
        return sessions
    }

    public static func importSessions(
        from browserSource: Browser,
        region: KimiRegion = .china,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        let query = BrowserCookieQuery(domains: region.cookieDomains, domainMatch: .exact)
        let log: (String) -> Void = { msg in self.emit(msg, logger: logger) }
        let sources = try Self.cookieClient.codexBarRecords(
            matching: query,
            in: browserSource,
            logger: log)

        return BrowserCookieProfiles.merge(sources).compactMap { profile in
            let cookies = BrowserCookieClient.makeHTTPCookies(profile.records, origin: query.origin)
            guard cookies.contains(where: { $0.name == "kimi-auth" }) else { return nil }
            log("Found kimi-auth cookie in \(profile.label)")
            return SessionInfo(cookies: cookies, sourceLabel: profile.label)
        }
    }

    static func localStorageTokens(
        region: KimiRegion,
        browserDetection: BrowserDetection = BrowserDetection(),
        localStorage: BrowserLocalStorageAPI = .live,
        now: Date = Date()) -> [String]
    {
        var seen = Set<String>()
        return localStorage.profiles(
            for: region.webBaseURL.absoluteString,
            browsers: ChromiumLocalStorageDiscovery.defaultBrowsers,
            using: browserDetection,
            logger: { Self.log.debug($0) })
            .flatMap(\.entries).compactMap { entry in
                guard entry.key == "access_token" else { return nil }
                let token = (try? JSONDecoder().decode(String.self, from: Data(entry.value.utf8)))
                    ?? entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard token.split(separator: ".", omittingEmptySubsequences: false).count == 3,
                      token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }),
                      let expiry = UsageFetcher.parseJWT(token)?["exp"] as? Double,
                      expiry.isFinite, expiry > now.timeIntervalSince1970,
                      seen.insert(token).inserted else { return nil }
                return token
            }
    }

    public static func importSession(
        region: KimiRegion = .china,
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let sessions = try self.importSessions(region: region, browserDetection: browserDetection, logger: logger)
        guard let first = sessions.first else {
            throw KimiCookieImportError.noCookies
        }
        return first
    }

    public static func hasSession(
        region: KimiRegion = .china,
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) -> Bool
    {
        do {
            return try !self.importSessions(region: region, browserDetection: browserDetection, logger: logger).isEmpty
        } catch {
            return false
        }
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[kimi-cookie] \(message)")
        self.log.debug(message)
    }
}

enum KimiCookieImportError: LocalizedError {
    case noCookies

    var errorDescription: String? {
        switch self {
        case .noCookies:
            "No Kimi session cookies found in browsers."
        }
    }
}
#endif
