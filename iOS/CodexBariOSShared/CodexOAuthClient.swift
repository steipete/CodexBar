import Foundation

public enum CodexOAuthClientError: LocalizedError, Sendable {
    case invalidCallback
    case stateMismatch
    case missingAuthorizationCode
    case invalidResponse(String)
    case serverError(Int, String?)
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidCallback:
            return "Codex login callback is invalid."
        case .stateMismatch:
            return "Codex login state mismatch."
        case .missingAuthorizationCode:
            return "Codex login did not return an authorization code."
        case let .invalidResponse(message):
            return "Codex token response is invalid: \(message)"
        case let .serverError(code, body):
            if let body, !body.isEmpty {
                return "Codex OAuth error \(code): \(body)"
            }
            return "Codex OAuth error \(code)."
        case let .networkError(error):
            return "Codex OAuth network error: \(error.localizedDescription)"
        }
    }
}

public enum CodexOAuthClient {
    public static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let callbackPort: UInt16 = 1455
    public static let callbackPath = "/auth/callback"
    public static let scope = "openid profile email offline_access"
    public static let originator = "codex_vscode"

    public static func makeAuthorizationRequest(redirectURI: URL) -> OAuthAuthorizationRequest {
        let state = OAuthSupport.randomURLSafeString()
        let codeVerifier = OAuthSupport.randomURLSafeString(length: 96)
        let codeChallenge = OAuthSupport.codeChallenge(for: codeVerifier)

        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: Self.originator),
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
        codeVerifier: String) async throws -> CodexCredentials
    {
        guard callbackURL.path == Self.callbackPath else {
            throw CodexOAuthClientError.invalidCallback
        }
        if let error = OAuthSupport.queryValue(named: "error", in: callbackURL) {
            let description = OAuthSupport.queryValue(named: "error_description", in: callbackURL)
            throw CodexOAuthClientError.invalidResponse([error, description].compactMap { $0 }.joined(separator: ": "))
        }
        guard OAuthSupport.queryValue(named: "state", in: callbackURL) == expectedState else {
            throw CodexOAuthClientError.stateMismatch
        }
        guard let code = OAuthSupport.queryValue(named: "code", in: callbackURL), !code.isEmpty else {
            throw CodexOAuthClientError.missingAuthorizationCode
        }
        return try await Self.exchangeAuthorizationCode(
            code: code,
            redirectURI: redirectURI,
            codeVerifier: codeVerifier)
    }

    public static func exchangeAuthorizationCode(
        code: String,
        redirectURI: URL,
        codeVerifier: String) async throws -> CodexCredentials
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
        return CodexCredentials(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            idToken: response.idToken,
            accountID: Self.accountID(from: response.idToken),
            lastRefresh: Date())
    }

    public static func refresh(_ credentials: CodexCredentials) async throws -> CodexCredentials {
        guard let refreshToken = credentials.refreshToken,
              !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return credentials
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: String] = [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response = try await Self.execute(request)
        let idToken = response.idToken ?? credentials.idToken
        return CodexCredentials(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? credentials.refreshToken,
            idToken: idToken,
            accountID: credentials.accountID ?? Self.accountID(from: idToken),
            lastRefresh: Date())
    }

    private static func execute(_ request: URLRequest) async throws -> TokenResponse {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CodexOAuthClientError.invalidResponse("Missing HTTP response")
            }
            guard http.statusCode == 200 else {
                throw CodexOAuthClientError.serverError(http.statusCode, String(data: data, encoding: .utf8))
            }
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            guard !decoded.accessToken.isEmpty else {
                throw CodexOAuthClientError.invalidResponse("Missing access token")
            }
            return decoded
        } catch let error as CodexOAuthClientError {
            throw error
        } catch {
            throw CodexOAuthClientError.networkError(error)
        }
    }

    private static func accountID(from idToken: String?) -> String? {
        guard let payload = OAuthSupport.decodedJWTPayload(idToken) else { return nil }
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        let value = (auth?["chatgpt_account_id"] as? String) ?? (payload["chatgpt_account_id"] as? String)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
    }
}
