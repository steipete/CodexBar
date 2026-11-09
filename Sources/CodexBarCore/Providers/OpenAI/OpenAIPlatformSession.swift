#if os(macOS)
import Foundation

/// The platform.openai.com session: the SPA's tokens from Chromium local storage, CodexBar's own refreshed pair,
/// and the session key that reads credit grants.
enum OpenAIPlatformSession {
    struct Tokens: Codable, Equatable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
    }

    private static let clientID = "app_2SKx67EdpoN0G6j64rFvigXD"
    private static let storeKey = KeychainCacheStore.Key.oauth(provider: .openai)
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let loginURL = URL(string: "https://api.openai.com/v1/dashboard/onboarding/login")!
    private static let creditGrantsURL = URL(string: "https://api.openai.com/v1/dashboard/billing/credit_grants")!
    private static let log = CodexBarLog.logger(LogCategories.provider(.openai, scope: "platform"))
    private static let signInHint = "Sign in at platform.openai.com in Chrome (or another Chromium browser), " +
        "then refresh."
    private static let responseError = "Could not read the OpenAI Platform session response."

    /// Returns the `credit_grants` JSON. Tokens are tried in order: each browser access token while unexpired,
    /// CodexBar's stored pair, a refresh with CodexBar's refresh token, then a refresh with each browser's.
    static func creditGrants(
        browserDetection: BrowserDetection,
        localStorage: BrowserLocalStorageAPI = .live,
        // The cookie-less ephemeral session keeps browser cookies off these bearer calls.
        transport: any ProviderHTTPTransport = CodexAuthenticatedHTTPTransport.current) async throws -> Data
    {
        let browser = self.browserTokens(browserDetection: browserDetection, localStorage: localStorage)
        guard !browser.isEmpty else {
            throw ProviderFetchClassifiedError(kind: .missingCredential, message: self.signInHint)
        }
        let fresh = Date().addingTimeInterval(60)
        for tokens in browser where tokens.expiresAt > fresh {
            if let body = try await self.grants(tokens.accessToken, transport: transport) { return body }
        }
        let stored: Tokens? = switch KeychainCacheStore.load(key: self.storeKey, as: Tokens.self) {
        case let .found(tokens): tokens
        case .missing, .invalid: nil
        case .interactionRequired, .temporarilyUnavailable:
            // A refresh now would rotate a pair that cannot be stored.
            throw ProviderFetchClassifiedError(
                kind: .networkFailure,
                message: "CodexBar's saved OpenAI Platform session cannot be read from the Keychain here. " +
                    self.signInHint)
        }
        if let stored, stored.expiresAt > fresh,
           let body = try await self.grants(stored.accessToken, transport: transport)
        {
            return body
        }
        for refreshToken in ([stored?.refreshToken] + browser.map(\.refreshToken)).compactMap(\.self) {
            guard let tokens = try await self.refreshed(refreshToken, transport: transport) else { continue }
            // A token issued seconds ago that is still refused will not be helped by rotating another one.
            if let body = try await self.grants(tokens.accessToken, transport: transport) { return body }
            break
        }
        throw ProviderFetchClassifiedError(
            kind: .authenticationExpired,
            message: "OpenAI Platform session expired. \(Self.signInHint)")
    }

    /// Reads the `oai-auth:onboard` tokens that platform.openai.com keeps in local storage, one pair per profile
    /// in the shared default browser order.
    private static func browserTokens(
        browserDetection: BrowserDetection,
        localStorage: BrowserLocalStorageAPI) -> [Tokens]
    {
        struct Onboard: Decodable {
            let accessToken: String
            let refreshToken: String
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
                let expiry = UsageFetcher.parseJWT(onboard.accessToken)?["exp"] as? Double
                return Tokens(
                    accessToken: onboard.accessToken,
                    refreshToken: onboard.refreshToken,
                    expiresAt: expiry.map(Date.init(timeIntervalSince1970:)) ?? .distantFuture)
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

    /// Persists every new pair, because each refresh rotates the refresh token. Nil when OpenAI rejects it.
    private static func refreshed(
        _ refreshToken: String,
        transport: any ProviderHTTPTransport) async throws -> Tokens?
    {
        struct Response: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Double
        }

        var request = URLRequest(url: self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        guard let data = try await self.send(request, rejecting: [400, 401], transport: transport) else { return nil }
        let response = try OpenAIPlatformCreditGrants.decode(Response.self, from: data, message: self.responseError)
        let tokens = Tokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? refreshToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn))
        KeychainCacheStore.store(key: self.storeKey, entry: tokens)
        return tokens
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
        return try OpenAIPlatformCreditGrants.decode(Response.self, from: data, message: self.responseError).user
            .session.sensitiveId
    }

    /// Nil when OpenAI answers with a status in `rejected`, so callers try the next token.
    private static func send(
        _ request: URLRequest,
        rejecting rejected: Set<Int> = [401],
        transport: any ProviderHTTPTransport) async throws -> Data?
    {
        var request = request
        request.timeoutInterval = 30
        let response = try await transport.response(for: request)
        let message = "OpenAI Platform error: HTTP \(response.statusCode)"
        switch response.statusCode {
        case 200..<300: return response.data
        case let code where rejected.contains(code): return nil
        case 429: throw ProviderFetchClassifiedError(kind: .rateLimited, message: message)
        case 500..<600: throw ProviderFetchClassifiedError(kind: .providerUnavailable, message: message)
        default: throw ProviderFetchClassifiedError(kind: .apiFailure, message: message)
        }
    }
}
#endif
