import Foundation

#if os(macOS)
import SweetCookieKit

// MARK: - Abacus Cookie Importer

public enum AbacusCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.abacusCookie)
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["abacus.ai", "apps.abacus.ai"]
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.abacus]?.browserCookieOrder ?? Browser.defaultImportOrder

    /// Exact cookie names known to carry Abacus session state.
    /// CSRF tokens are deliberately excluded — they are present in anonymous
    /// jars and do not indicate an authenticated session.
    private static let knownSessionCookieNames: Set<String> = [
        "sessionid", "session_id", "session_token",
        "auth_token", "access_token",
    ]

    /// Substrings that indicate a session or auth cookie (applied only when
    /// no exact-name match is found). Deliberately excludes overly broad
    /// patterns like "id" and "token" that match analytics/CSRF cookies.
    private static let sessionCookieSubstrings = ["session", "auth", "sid", "jwt"]

    /// Cookie name prefixes that indicate a non-session cookie even when a
    /// substring match would otherwise accept it (e.g. "csrftoken").
    private static let excludedCookiePrefixes = ["csrf", "_ga", "_gid", "tracking", "analytics"]

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

    /// Returns all candidate sessions across browsers/profiles, ordered by
    /// import priority.  Callers should try each in turn so that a stale
    /// session in the first source doesn't block a valid one further down.
    ///
    /// Defaults to Chrome-only per AGENTS.md guideline. Pass an empty
    /// `preferredBrowsers` list to fall back to the full descriptor-defined
    /// import order (Safari, Firefox, etc.) when Chrome has no cookies.
    public static func importSessions(
        browserDetection: BrowserDetection = BrowserDetection(),
        preferredBrowsers: [Browser] = [.chrome],
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        var candidates: [SessionInfo] = []
        let installedBrowsers = preferredBrowsers.isEmpty
            ? self.cookieImportOrder.cookieImportCandidates(using: browserDetection)
            : preferredBrowsers.cookieImportCandidates(using: browserDetection)

        for browserSource in installedBrowsers {
            do {
                let query = BrowserCookieQuery(domains: self.cookieDomains)
                let sources = try Self.cookieClient.codexBarRecords(
                    matching: query,
                    in: browserSource,
                    logger: { msg in self.emit(msg, logger: logger) })
                for source in sources where !source.records.isEmpty {
                    let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    guard !httpCookies.isEmpty else { continue }

                    guard Self.containsSessionCookie(httpCookies) else {
                        self.emit(
                            "Skipping \(source.label): no session cookie found",
                            logger: logger)
                        continue
                    }

                    self.emit(
                        "Found \(httpCookies.count) session cookies in \(source.label)",
                        logger: logger)
                    candidates.append(SessionInfo(cookies: httpCookies, sourceLabel: source.label))
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                self.emit(
                    "\(browserSource.displayName) cookie import failed: \(error.localizedDescription)",
                    logger: logger)
            }
        }

        guard !candidates.isEmpty else {
            throw AbacusUsageError.noSessionCookie
        }
        return candidates
    }

    /// Cheap check for whether any browser has an Abacus session cookie,
    /// used by the fetch strategy's `isAvailable()`.
    public static func hasSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        preferredBrowsers: [Browser] = [.chrome],
        logger: ((String) -> Void)? = nil) -> Bool
    {
        do {
            return try !self.importSessions(
                browserDetection: browserDetection,
                preferredBrowsers: preferredBrowsers,
                logger: logger).isEmpty
        } catch {
            return false
        }
    }

    /// Returns `true` if the cookie set contains at least one cookie whose name
    /// indicates session or authentication state.  Checks exact known names
    /// first, then falls back to conservative substring matching.
    private static func containsSessionCookie(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { cookie in
            let lower = cookie.name.lowercased()
            if self.knownSessionCookieNames.contains(lower) { return true }
            if self.excludedCookiePrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
            return self.sessionCookieSubstrings.contains { lower.contains($0) }
        }
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[abacus-cookie] \(message)")
        self.log.debug(message)
    }
}
#endif
