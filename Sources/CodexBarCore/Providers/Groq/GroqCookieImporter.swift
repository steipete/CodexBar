import Foundation

#if os(macOS)
import SweetCookieKit

public enum GroqCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["console.groq.com", "groq.com"]
    private static let sessionJWTCookieName = "stytch_session_jwt"
    private static let userPrefsCookieName = "user-preferences"

    public struct SessionInfo: Sendable {
        public let jwt: String
        public let orgID: String?
        public let sourceLabel: String

        public init(jwt: String, orgID: String?, sourceLabel: String) {
            self.jwt = jwt
            self.orgID = orgID
            self.sourceLabel = sourceLabel
        }
    }

    public static func importSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let log: (String) -> Void = { msg in logger?("[groq-cookie] \(msg)") }
        let importOrder = ProviderDefaults.metadata[.groq]?.browserCookieOrder
            ?? Browser.defaultImportOrder
        let candidates = importOrder.cookieImportCandidates(using: browserDetection)

        for browserSource in candidates {
            do {
                let query = BrowserCookieQuery(domains: self.cookieDomains)
                let sources = try Self.cookieClient.records(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    guard let jwtCookie = httpCookies.first(where: { $0.name == self.sessionJWTCookieName }),
                          !jwtCookie.value.isEmpty
                    else {
                        log("Skipping \(source.label): no \(self.sessionJWTCookieName) cookie")
                        continue
                    }
                    let orgID = Self.extractOrgID(from: httpCookies, jwt: jwtCookie.value)
                    log("Found Groq session JWT in \(source.label), orgID=\(orgID ?? "unknown")")
                    return SessionInfo(jwt: jwtCookie.value, orgID: orgID, sourceLabel: source.label)
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        throw GroqCookieImportError.noCookies
    }

    public static func hasSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) -> Bool
    {
        (try? self.importSession(browserDetection: browserDetection, logger: logger)) != nil
    }

    // Tries user-preferences cookie first, then falls back to JWT payload claim.
    private static func extractOrgID(from cookies: [HTTPCookie], jwt: String) -> String? {
        if let prefsCookie = cookies.first(where: { $0.name == self.userPrefsCookieName }),
           let data = prefsCookie.value.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let orgID = json["current-org"] as? String,
           !orgID.isEmpty
        {
            return orgID
        }
        return GroqSettingsReader.extractOrgID(fromJWT: jwt)
    }
}

public enum GroqCookieImportError: LocalizedError, Sendable {
    case noCookies

    public var errorDescription: String? {
        "No Groq session cookies found in browsers. Open console.groq.com in your browser and log in."
    }
}
#endif
