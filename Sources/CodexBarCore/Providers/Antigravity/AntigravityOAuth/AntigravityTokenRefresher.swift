import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AntigravityTokenRefresher {
    private static let log = CodexBarLog.logger(LogCategories.antigravity)
    private static let httpTimeout: TimeInterval = 15.0

    public struct RefreshResult: Sendable {
        public let accessToken: String
        public let expiresAt: Date
        public let email: String?
    }

    public static func refreshAccessToken(refreshToken: String) async throws -> RefreshResult {
        let params = [
            "client_id": AntigravityOAuthConfig.clientID,
            "client_secret": AntigravityOAuthConfig.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]

        let body = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")

        guard let url = URL(string: AntigravityOAuthConfig.tokenURL) else {
            throw AntigravityOAuthCredentialsError.networkError("Invalid token URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = self.httpTimeout

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AntigravityOAuthCredentialsError.networkError("Invalid response")
        }

        guard http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            if errorBody.lowercased().contains("invalid_grant") {
                self.log.warning("Antigravity refresh token is invalid (invalid_grant)")
                throw AntigravityOAuthCredentialsError.invalidGrant
            }
            throw AntigravityOAuthCredentialsError.refreshFailed("HTTP \(http.statusCode): \(errorBody)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int
        else {
            throw AntigravityOAuthCredentialsError.decodeFailed("Invalid token response")
        }

        let expiresAt = Date(timeIntervalSinceNow: TimeInterval(expiresIn))

        var email: String?
        do {
            email = try await self.fetchUserEmail(accessToken: accessToken)
        } catch {
            self.log.debug("Failed to fetch user email during refresh: \(error.localizedDescription)")
        }

        self.log.info("Antigravity access token refreshed", metadata: [
            "expiresIn": "\(expiresIn)s",
            "email": email ?? "unknown",
        ])

        return RefreshResult(accessToken: accessToken, expiresAt: expiresAt, email: email)
    }

    public static func buildCredentialsFromRefreshToken(
        refreshToken: String,
        fallbackEmail: String? = nil) async throws -> AntigravityOAuthCredentials
    {
        let result = try await self.refreshAccessToken(refreshToken: refreshToken)
        return AntigravityOAuthCredentials(
            accessToken: result.accessToken,
            refreshToken: refreshToken,
            expiresAt: result.expiresAt,
            email: result.email ?? fallbackEmail,
            scopes: AntigravityOAuthConfig.scopes)
    }

    public static func fetchUserEmail(accessToken: String) async throws -> String {
        guard let url = URL(string: AntigravityOAuthConfig.userInfoURL) else {
            throw AntigravityOAuthCredentialsError.networkError("Invalid userinfo URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = self.httpTimeout

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AntigravityOAuthCredentialsError.networkError("Failed to fetch user info: HTTP \(statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String
        else {
            throw AntigravityOAuthCredentialsError.decodeFailed("Missing email in userinfo response")
        }

        return email
    }
}
