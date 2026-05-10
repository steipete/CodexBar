import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CodexTokenRefresher {
    private static let refreshEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    public enum RefreshError: LocalizedError, Sendable {
        case expired
        case revoked
        case reused
        case networkError(Error)
        case invalidResponse(String)

        public var errorDescription: String? {
            switch self {
            case .expired:
                "Refresh token expired. Please run `codex` to log in again."
            case .revoked:
                "Refresh token was revoked. Please run `codex` to log in again."
            case .reused:
                "Refresh token was already used. Please run `codex` to log in again."
            case let .networkError(error):
                "Network error during token refresh: \(error.localizedDescription)"
            case let .invalidResponse(message):
                "Invalid refresh response: \(message)"
            }
        }
    }

    public static func refresh(_ credentials: CodexOAuthCredentials) async throws -> CodexOAuthCredentials {
        guard !credentials.refreshToken.isEmpty else {
            return credentials
        }

        var request = URLRequest(url: Self.refreshEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "scope": "openid profile email",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RefreshError.invalidResponse("No HTTP response")
            }

            guard http.statusCode == 200 else {
                throw Self.refreshFailureError(statusCode: http.statusCode, data: data)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RefreshError.invalidResponse("Invalid JSON")
            }

            let newAccessToken = json["access_token"] as? String ?? credentials.accessToken
            let newRefreshToken = json["refresh_token"] as? String ?? credentials.refreshToken
            let newIdToken = json["id_token"] as? String ?? credentials.idToken

            return CodexOAuthCredentials(
                accessToken: newAccessToken,
                refreshToken: newRefreshToken,
                idToken: newIdToken,
                accountId: credentials.accountId,
                lastRefresh: Date())
        } catch let error as RefreshError {
            throw error
        } catch {
            throw RefreshError.networkError(error)
        }
    }

    private static func extractErrorCode(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let code = error["code"] as? String { return code }
        if let error = json["error"] as? String { return error }
        return json["code"] as? String
    }

    private static func refreshFailureError(statusCode: Int, data: Data) -> RefreshError {
        if let errorCode = extractErrorCode(from: data) {
            switch errorCode.lowercased() {
            case "refresh_token_expired":
                return .expired
            case "refresh_token_reused":
                return .reused
            case "invalid_grant", "refresh_token_invalidated":
                return .revoked
            default:
                break
            }
        }

        if statusCode == 401 {
            return .expired
        }

        return .invalidResponse("Status \(statusCode)")
    }
}

#if DEBUG
extension CodexTokenRefresher {
    static func _refreshFailureErrorForTesting(statusCode: Int, data: Data) -> RefreshError {
        self.refreshFailureError(statusCode: statusCode, data: data)
    }
}
#endif
