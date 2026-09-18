import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum VertexAITokenRefresher {
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    public enum RefreshError: LocalizedError, Sendable {
        case expired
        case revoked
        case networkError(Error)
        case invalidResponse(String)

        public var errorDescription: String? {
            switch self {
            case .expired:
                "Refresh token expired. Run `gcloud auth application-default login` again."
            case .revoked:
                "Refresh token was revoked. Run `gcloud auth application-default login` again."
            case let .networkError(error):
                "Network error during token refresh: \(error.localizedDescription)"
            case let .invalidResponse(message):
                "Invalid refresh response: \(message)"
            }
        }
    }

    public static func refresh(_ credentials: VertexAIOAuthCredentials) async throws -> VertexAIOAuthCredentials {
        try await self.refresh(credentials, session: ProviderHTTPClient.shared)
    }

    static func refresh(
        _ credentials: VertexAIOAuthCredentials,
        session transport: any ProviderHTTPTransport) async throws -> VertexAIOAuthCredentials
    {
        guard !credentials.refreshToken.isEmpty else {
            throw RefreshError.invalidResponse("No refresh token available")
        }

        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "client_id": credentials.clientId,
            "client_secret": credentials.clientSecret,
            "refresh_token": credentials.refreshToken,
            "grant_type": "refresh_token",
        ]

        request.httpBody = FormURLEncoding.body(bodyParams)

        do {
            let response = try await transport.response(for: request)
            let data = response.data

            if response.statusCode == 400 || response.statusCode == 401 {
                if let errorCode = Self.extractErrorCode(from: data) {
                    switch errorCode.lowercased() {
                    case "invalid_grant":
                        throw RefreshError.expired
                    case "unauthorized_client":
                        throw RefreshError.revoked
                    default:
                        throw RefreshError.invalidResponse("Error: \(errorCode)")
                    }
                }
                throw RefreshError.expired
            }

            guard response.statusCode == 200 else {
                throw RefreshError.invalidResponse("Status \(response.statusCode)")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RefreshError.invalidResponse("Invalid JSON")
            }

            guard let newAccessToken = json["access_token"] as? String,
                  !newAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw RefreshError.invalidResponse("Missing access token")
            }
            let expiresIn = json["expires_in"] as? Double ?? 3600
            let newExpiryDate = Date().addingTimeInterval(expiresIn)

            let idToken = json["id_token"] as? String
            let email = VertexAIIDToken.email(from: idToken) ?? credentials.email

            return VertexAIOAuthCredentials(
                accessToken: newAccessToken,
                refreshToken: credentials.refreshToken,
                clientId: credentials.clientId,
                clientSecret: credentials.clientSecret,
                projectId: credentials.projectId,
                email: email,
                expiryDate: newExpiryDate)
        } catch let error as RefreshError {
            throw error
        } catch {
            throw RefreshError.networkError(error)
        }
    }

    private static func extractErrorCode(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["error"] as? String
    }
}
