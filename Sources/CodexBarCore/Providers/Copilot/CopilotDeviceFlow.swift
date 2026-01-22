import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CopilotDeviceFlow: Sendable {
    private let clientID = "Iv1.b507a08c87ecfe98" // VS Code Client ID
    private let scopes = "read:user"

    public struct DeviceCodeResponse: Decodable, Sendable {
        public let deviceCode: String
        public let userCode: String
        public let verificationUri: String
        public let expiresIn: Int
        public let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationUri = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }
    }

    public struct AccessTokenResponse: Decodable, Sendable {
        public let accessToken: String
        public let tokenType: String
        public let scope: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case scope
        }
    }

    public init() {}

    public func requestDeviceCode() async throws -> DeviceCodeResponse {
        let components = URLComponents(string: "https://github.com/login/device/code")!
        let request = URLRequest(url: components.url!)

        var postRequest = request
        postRequest.httpMethod = "POST"
        postRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        postRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": self.clientID,
            "scope": self.scopes,
        ]
        postRequest.httpBody = Self.formURLEncodedBody(body)

        let (data, response) = try await URLSession.shared.data(for: postRequest)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    public func pollForToken(deviceCode: String, interval: Int) async throws -> String {
        let url = URL(string: "https://github.com/login/oauth/access_token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": self.clientID,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ]
        request.httpBody = Self.formURLEncodedBody(body)

        while true {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            try Task.checkCancellation()

            let (data, _) = try await URLSession.shared.data(for: request)

            // Check for error in JSON
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String
            {
                if error == "authorization_pending" {
                    continue
                }
                if error == "slow_down" {
                    try await Task.sleep(nanoseconds: 5_000_000_000) // Add 5s
                    continue
                }
                if error == "expired_token" {
                    throw URLError(.timedOut)
                }
                throw URLError(.userAuthenticationRequired) // Generic failure
            }

            if let tokenResponse = try? JSONDecoder().decode(AccessTokenResponse.self, from: data) {
                return tokenResponse.accessToken
            }
        }
    }

    private static func formURLEncodedBody(_ parameters: [String: String]) -> Data {
        let pairs = parameters
            .map { key, value in
                "\(Self.formEncode(key))=\(Self.formEncode(value))"
            }
            .joined(separator: "&")
        return Data(pairs.utf8)
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
