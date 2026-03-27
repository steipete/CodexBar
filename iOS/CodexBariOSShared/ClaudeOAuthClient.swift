import Foundation

public enum ClaudeOAuthClientError: LocalizedError, Sendable {
    case invalidCallback
    case stateMismatch
    case missingAuthorizationCode
    case invalidResponse(String)
    case serverError(Int, String?)
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidCallback:
            return "Claude login callback is invalid."
        case .stateMismatch:
            return "Claude login state mismatch."
        case .missingAuthorizationCode:
            return "Claude login did not return an authorization code."
        case let .invalidResponse(message):
            return "Claude token response is invalid: \(message)"
        case let .serverError(code, body):
            if let body, !body.isEmpty {
                return "Claude OAuth error \(code): \(body)"
            }
            return "Claude OAuth error \(code)."
        case let .networkError(error):
            return "Claude OAuth network error: \(error.localizedDescription)"
        }
    }
}

public enum ClaudeOAuthClient {
    public static let authorizeURL = URL(string: "https://claude.com/cai/oauth/authorize")!
    public static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let redirectURI = URL(string: "https://platform.claude.com/oauth/code/callback")!
    public static let successURI = URL(string: "https://platform.claude.com/oauth/code/success?app=claude-code")!
    public static let callbackPath = "/oauth/code/callback"
    public static let successPath = "/oauth/code/success"
    public static let scope = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    public static func makeAuthorizationRequest(redirectURI: URL = Self.redirectURI) -> OAuthAuthorizationRequest {
        let state = OAuthSupport.randomURLSafeString()
        let codeVerifier = OAuthSupport.randomURLSafeString(length: 96)
        let codeChallenge = OAuthSupport.codeChallenge(for: codeVerifier)

        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]

        return OAuthAuthorizationRequest(
            url: components?.url ?? Self.authorizeURL,
            state: state,
            codeVerifier: codeVerifier)
    }

    public static func credentials(
        from callbackURL: URL,
        expectedState: String,
        redirectURI: URL,
        codeVerifier: String) async throws -> ClaudeCredentials
    {
        let supportedPaths = [redirectURI.path, Self.callbackPath, Self.successPath]
        guard supportedPaths.contains(callbackURL.path) else {
            throw ClaudeOAuthClientError.invalidCallback
        }
        if let error = OAuthSupport.queryValue(named: "error", in: callbackURL) {
            let description = OAuthSupport.queryValue(named: "error_description", in: callbackURL)
            throw ClaudeOAuthClientError.invalidResponse([error, description].compactMap { $0 }.joined(separator: ": "))
        }
        guard OAuthSupport.queryValue(named: "state", in: callbackURL) == expectedState else {
            throw ClaudeOAuthClientError.stateMismatch
        }
        guard let code = OAuthSupport.queryValue(named: "code", in: callbackURL), !code.isEmpty else {
            throw ClaudeOAuthClientError.missingAuthorizationCode
        }
        return try await Self.exchangeAuthorizationCode(
            code: code,
            redirectURI: redirectURI,
            codeVerifier: codeVerifier)
    }

    public static func credentials(
        authorizationCode: String,
        returnedState: String?,
        expectedState: String,
        redirectURI: URL,
        codeVerifier: String) async throws -> ClaudeCredentials
    {
        if let returnedState, returnedState != expectedState {
            throw ClaudeOAuthClientError.stateMismatch
        }
        guard !authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeOAuthClientError.missingAuthorizationCode
        }
        return try await Self.exchangeAuthorizationCode(
            code: authorizationCode,
            redirectURI: redirectURI,
            codeVerifier: codeVerifier)
    }

    public static func exchangeAuthorizationCode(
        code: String,
        redirectURI: URL,
        codeVerifier: String) async throws -> ClaudeCredentials
    {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = OAuthSupport.formEncodedBody([
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
        ])

        let response = try await Self.execute(request)
        return Self.credentials(from: response)
    }

    public static func refresh(_ credentials: ClaudeCredentials) async throws -> ClaudeCredentials {
        guard let refreshToken = credentials.refreshToken,
              !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return credentials
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = OAuthSupport.formEncodedBody([
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: Self.clientID),
        ])

        let response = try await Self.execute(request)
        let refreshed = Self.credentials(from: response)
        return ClaudeCredentials(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? credentials.refreshToken,
            expiresAt: refreshed.expiresAt,
            scopes: refreshed.scopes.isEmpty ? credentials.scopes : refreshed.scopes,
            rateLimitTier: refreshed.rateLimitTier ?? credentials.rateLimitTier)
    }

    private static func execute(_ request: URLRequest) async throws -> TokenResponse {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ClaudeOAuthClientError.invalidResponse("Missing HTTP response")
            }
            guard http.statusCode == 200 else {
                throw ClaudeOAuthClientError.serverError(http.statusCode, String(data: data, encoding: .utf8))
            }
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            guard !decoded.accessToken.isEmpty else {
                throw ClaudeOAuthClientError.invalidResponse("Missing access token")
            }
            return decoded
        } catch let error as ClaudeOAuthClientError {
            throw error
        } catch {
            throw ClaudeOAuthClientError.networkError(error)
        }
    }

    private static func credentials(from response: TokenResponse) -> ClaudeCredentials {
        let expiresAt = response.expiresIn.map { Date(timeIntervalSinceNow: TimeInterval($0)) }
        return ClaudeCredentials(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: expiresAt,
            scopes: response.scopes ?? OAuthSupport.parseScopes(response.scope),
            rateLimitTier: response.rateLimitTier)
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let scope: String?
    let scopes: [String]?
    let rateLimitTier: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case scopes
        case rateLimitTier
    }
}
