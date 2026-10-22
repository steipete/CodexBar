import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CopilotDeviceFlow: Sendable {
    public static let defaultHost = "github.com"

    private let clientID = "Iv1.b507a08c87ecfe98" // VS Code Client ID
    private let scopes = "read:user"
    private let host: String
    private let transport: any ProviderHTTPTransport

    public struct DeviceCodeResponse: Decodable, Sendable {
        public let deviceCode: String
        public let userCode: String
        public let verificationUri: String
        public let verificationUriComplete: String?
        public let expiresIn: Int
        public let interval: Int

        public var verificationURLToOpen: String {
            self.verificationUriComplete ?? self.verificationUri
        }

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationUri = "verification_uri"
            case verificationUriComplete = "verification_uri_complete"
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

    public init(
        enterpriseHost: String? = nil,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared)
    {
        self.transport = transport
        self.host = Self.normalizedHost(enterpriseHost)
    }

    public var deviceCodeURL: URL? {
        Self.makeRequestURL(host: self.host, path: "/login/device/code")
    }

    public var accessTokenURL: URL? {
        Self.makeRequestURL(host: self.host, path: "/login/oauth/access_token")
    }

    public static func normalizedHost(_ raw: String?) -> String {
        guard var host = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return self.defaultHost
        }
        let componentsValue = host.contains("://") ? host : "https://\(host)"
        if let components = URLComponents(string: componentsValue),
           let parsedHost = components.host,
           !parsedHost.isEmpty
        {
            host = parsedHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let port = components.port, port != 443 {
                host += ":\(port)"
            }
        } else {
            if host.hasPrefix("https://") {
                host.removeFirst("https://".count)
            } else if host.hasPrefix("http://") {
                host.removeFirst("http://".count)
            }
            host = host.split(separator: "/", maxSplits: 1).first.map(String.init) ?? host
        }
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return normalized.isEmpty ? Self.defaultHost : normalized
    }

    public func requestDeviceCode() async throws -> DeviceCodeResponse {
        guard let deviceCodeURL = self.deviceCodeURL else {
            throw URLError(.badURL)
        }
        let request = URLRequest(url: deviceCodeURL)

        var postRequest = request
        postRequest.httpMethod = "POST"
        postRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        postRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": self.clientID,
            "scope": self.scopes,
        ]
        postRequest.httpBody = FormURLEncoding.body(body)

        let response = try await self.transport.response(for: postRequest)

        guard response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(DeviceCodeResponse.self, from: response.data)
    }

    public func pollForToken(deviceCode: String, interval: Int, expiresIn: Int = 900) async throws -> String {
        guard let accessTokenURL = self.accessTokenURL else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: accessTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": self.clientID,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ]
        request.httpBody = FormURLEncoding.body(body)

        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, expiresIn)))
        var pollingInterval = max(1, interval)
        while ContinuousClock.now < deadline {
            try await Task.sleep(
                until: min(ContinuousClock.now.advanced(by: .seconds(pollingInterval)), deadline), clock: .continuous)
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }

            request.timeoutInterval = min(
                30,
                max(1, Double(ContinuousClock.now.duration(to: deadline).components.seconds)))
            let response = try await self.transport.response(for: request)

            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            guard response.statusCode == 200 else { throw URLError(.badServerResponse) }

            // Check for error in JSON
            if let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
               let error = json["error"] as? String
            {
                if error == "authorization_pending" {
                    continue
                }
                if error == "slow_down" {
                    pollingInterval += 5
                    continue
                }
                if error == "access_denied" { throw URLError(.userCancelledAuthentication) }
                if error == "expired_token" {
                    throw URLError(.timedOut)
                }
                throw URLError(.userAuthenticationRequired) // Generic failure
            }

            guard let tokenResponse = try? JSONDecoder().decode(AccessTokenResponse.self, from: response.data),
                  !tokenResponse.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw URLError(.cannotParseResponse) }
            return tokenResponse.accessToken
        }
        throw URLError(.timedOut)
    }

    static func makeRequestURL(host: String, path: String) -> URL? {
        URL(string: "https://\(host)\(path)")
    }
}
