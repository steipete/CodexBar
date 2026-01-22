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

        let bodyString = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RefreshError.invalidResponse("No HTTP response")
            }

            if http.statusCode == 400 || http.statusCode == 401 {
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

            guard http.statusCode == 200 else {
                throw RefreshError.invalidResponse("Status \(http.statusCode)")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RefreshError.invalidResponse("Invalid JSON")
            }

            let newAccessToken = json["access_token"] as? String ?? credentials.accessToken
            let expiresIn = json["expires_in"] as? Double ?? 3600
            let newExpiryDate = Date().addingTimeInterval(expiresIn)

            // Extract email from new ID token if present
            let idToken = json["id_token"] as? String
            let email = Self.extractEmailFromIdToken(idToken) ?? credentials.email

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

    private static func extractEmailFromIdToken(_ token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }

        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }

        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return json["email"] as? String
    }
}
