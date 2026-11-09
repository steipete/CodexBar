#if os(macOS)
import Foundation

/// Reads API credit grants with the platform.openai.com session that Chromium browsers keep in local storage.
/// The session is read-only: CodexBar never refreshes or stores its tokens.
enum OpenAIPlatformSession {
    private static let loginURL = URL(string: "https://api.openai.com/v1/dashboard/onboarding/login")!
    private static let creditGrantsURL = URL(string: "https://api.openai.com/v1/dashboard/billing/credit_grants")!
    private static let log = CodexBarLog.logger(LogCategories.provider(.openai, scope: "platform"))

    /// Returns the `credit_grants` JSON. Each profile's access token is tried in the shared default browser order
    /// while its JWT `exp` lies ahead, and a rejected token moves on to the next profile.
    static func creditGrants(
        browserDetection: BrowserDetection,
        localStorage: BrowserLocalStorageAPI = .live,
        // The cookie-less ephemeral session keeps browser cookies off these bearer calls.
        transport: any ProviderHTTPTransport = CodexAuthenticatedHTTPTransport.current) async throws -> Data
    {
        let accessTokens = self.browserAccessTokens(browserDetection: browserDetection, localStorage: localStorage)
        guard !accessTokens.isEmpty else {
            throw ProviderFetchClassifiedError(
                kind: .missingCredential,
                message: "Sign in at platform.openai.com in Chrome (or another Chromium browser), then refresh.")
        }
        let now = Date().timeIntervalSince1970
        for accessToken in accessTokens
            where (UsageFetcher.parseJWT(accessToken)?["exp"] as? Double ?? .infinity) > now
        {
            if let body = try await self.grants(accessToken, transport: transport) { return body }
        }
        throw ProviderFetchClassifiedError(
            kind: .authenticationExpired,
            message: "OpenAI Platform session expired. Open platform.openai.com in the browser you signed in " +
                "with to renew it, then refresh.")
    }

    /// Reads the access token of the `oai-auth:onboard` entry that platform.openai.com keeps in local storage,
    /// one per profile in the shared default browser order.
    private static func browserAccessTokens(
        browserDetection: BrowserDetection,
        localStorage: BrowserLocalStorageAPI) -> [String]
    {
        struct Onboard: Decodable {
            let accessToken: String
        }

        return localStorage.profiles(
            for: "https://platform.openai.com",
            browsers: ChromiumLocalStorageDiscovery.defaultBrowsers,
            using: browserDetection,
            logger: { self.log.debug($0) })
            .compactMap { profile in
                guard let value = profile.entries.first(where: { $0.key == "oai-auth:onboard" })?.value,
                      let onboard = try? JSONDecoder().decode(Onboard.self, from: Data(value.utf8))
                else { return nil }
                self.log.debug("Found OpenAI Platform session in \(profile.id)")
                return onboard.accessToken
            }
    }

    /// Nil when OpenAI rejects the access token, so the caller tries the next one.
    private static func grants(_ accessToken: String, transport: any ProviderHTTPTransport) async throws -> Data? {
        guard let sessionKey = try await self.sessionKey(accessToken: accessToken, transport: transport) else {
            return nil
        }
        var request = URLRequest(url: self.creditGrantsURL)
        request.setValue("Bearer \(sessionKey)", forHTTPHeaderField: "Authorization")
        return try await self.send(request, transport: transport)
    }

    private static func sessionKey(accessToken: String, transport: any ProviderHTTPTransport) async throws -> String? {
        struct Response: Decodable {
            struct User: Decodable {
                struct Session: Decodable {
                    let sensitiveId: String
                }

                let session: Session
            }

            let user: User
        }

        var request = URLRequest(url: self.loginURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"app":"api"}"#.utf8)
        guard let data = try await self.send(request, transport: transport) else { return nil }
        return try OpenAIPlatformCreditGrants.decode(
            Response.self,
            from: data,
            message: "Could not read the OpenAI Platform session response.").user.session.sensitiveId
    }

    /// Nil when OpenAI answers HTTP 401, so callers try the next token.
    private static func send(_ request: URLRequest, transport: any ProviderHTTPTransport) async throws -> Data? {
        var request = request
        request.timeoutInterval = 30
        let response = try await transport.response(for: request)
        let message = "OpenAI Platform error: HTTP \(response.statusCode)"
        switch response.statusCode {
        case 200..<300: return response.data
        case 401: return nil
        case 429: throw ProviderFetchClassifiedError(kind: .rateLimited, message: message)
        case 500..<600: throw ProviderFetchClassifiedError(kind: .providerUnavailable, message: message)
        default: throw ProviderFetchClassifiedError(kind: .apiFailure, message: message)
        }
    }
}
#endif
