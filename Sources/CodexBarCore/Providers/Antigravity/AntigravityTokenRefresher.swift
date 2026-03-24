import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Token Refresher

public struct AntigravityTokenRefresher: Sendable {
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let log = CodexBarLog.logger(LogCategories.antigravity)

    /// Build the URLRequest for a refresh-token grant. Exposed for testing.
    public static func buildRefreshRequest(refreshToken: String) -> URLRequest {
        var request = URLRequest(url: URL(string: self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        request.httpBody = AntigravityOAuthFormEncoding.bodyData([
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: AntigravityOAuthConfig.clientId),
            URLQueryItem(name: "client_secret", value: AntigravityOAuthConfig.clientSecret),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ])
        return request
    }

    /// Refresh an expired access token using the stored refresh token.
    public static func refresh(
        refreshToken: String,
        timeout: TimeInterval = 10.0) async throws -> AntigravityOAuthTokens
    {
        let request = self.buildRefreshRequest(refreshToken: refreshToken)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityOAuthError.tokenRefreshFailed("Invalid response")
        }

        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            self.log.error("Token refresh failed", metadata: [
                "status": "\(http.statusCode)",
                "body": body,
            ])
            throw AntigravityOAuthError.tokenRefreshFailed("HTTP \(http.statusCode)")
        }

        let decoded = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
        return AntigravityOAuthTokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token ?? refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)),
            email: nil,
            projectId: nil)
    }
}

// MARK: - Response type

private struct TokenRefreshResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int
}
