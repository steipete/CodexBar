import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native Swift implementation of Codex's OAuth 2.0 Device Authorization Grant.
///
/// Mirrors the flow used by the ChatGPT Codex proxy reference implementation:
///   1. `POST /api/accounts/deviceauth/usercode` → obtain user code + device_auth_id.
///   2. Show the user a verification URL and poll
///      `POST /api/accounts/deviceauth/token` until the user authorizes.
///   3. Exchange the returned authorization code at `POST /oauth/token` for
///      access / refresh / id tokens.
///
/// The result is returned as a `CodexOAuthCredentials` ready to be persisted
/// by `CodexOAuthCredentialsStore.save(_:env:)`.
public struct CodexDeviceFlow: Sendable {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let authBaseURL = URL(string: "https://auth.openai.com")!
    public static let redirectURI = "https://auth.openai.com/deviceauth/callback"

    public struct DeviceCodeResponse: Sendable {
        public let userCode: String
        public let deviceAuthID: String
        /// Polling interval in seconds, clamped to a sane minimum of 5s.
        public let intervalSeconds: Int
        public let verificationURL: URL

        public init(
            userCode: String,
            deviceAuthID: String,
            intervalSeconds: Int,
            verificationURL: URL)
        {
            self.userCode = userCode
            self.deviceAuthID = deviceAuthID
            self.intervalSeconds = intervalSeconds
            self.verificationURL = verificationURL
        }
    }

    public enum Error: Swift.Error, Sendable, Equatable {
        case requestFailed(status: Int, body: String?)
        case invalidResponse
        case timedOut
        case missingTokens
    }

    private let userAgent: String
    private let urlSession: URLSession

    public init(
        userAgent: String = CodexDeviceFlow.defaultUserAgent(),
        urlSession: URLSession = .shared)
    {
        self.userAgent = userAgent
        self.urlSession = urlSession
    }

    public static func defaultUserAgent() -> String {
        "codex_cli_rs/0.0.0 (CodexBar; macOS)"
    }

    // MARK: - Step 1: request device code

    public func requestDeviceCode() async throws -> DeviceCodeResponse {
        let url = Self.authBaseURL.appendingPathComponent("/api/accounts/deviceauth/usercode")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientID,
        ])

        let (data, response) = try await self.urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw Error.requestFailed(status: http.statusCode, body: Self.responseBodyString(data))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userCode = json["user_code"] as? String,
              let deviceAuthID = json["device_auth_id"] as? String,
              !userCode.isEmpty, !deviceAuthID.isEmpty
        else {
            throw Error.invalidResponse
        }

        let interval = Self.decodeInterval(json["interval"])

        return DeviceCodeResponse(
            userCode: userCode,
            deviceAuthID: deviceAuthID,
            intervalSeconds: interval,
            verificationURL: Self.verificationURL(userCode: userCode))
    }

    // MARK: - Step 2/3: poll for tokens + exchange

    public func pollForTokens(
        deviceAuthID: String,
        userCode: String,
        intervalSeconds: Int,
        deadline: Date) async throws -> CodexOAuthCredentials
    {
        let pollURL = Self.authBaseURL.appendingPathComponent("/api/accounts/deviceauth/token")
        var pollRequest = URLRequest(url: pollURL)
        pollRequest.httpMethod = "POST"
        pollRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        pollRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        pollRequest.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        pollRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_auth_id": deviceAuthID,
            "user_code": userCode,
        ])

        // NOTE: Codex's device endpoint has no explicit user-deny signal.
        // A user who cancels in the browser simply lets the code expire;
        // we surface that as `.timedOut` once the deadline passes.
        let clampedInterval = max(intervalSeconds, 5)

        while true {
            try Task.checkCancellation()
            if Date() >= deadline {
                throw Error.timedOut
            }

            try await Task.sleep(nanoseconds: UInt64(clampedInterval) * 1_000_000_000)
            try Task.checkCancellation()

            let (data, response) = try await self.urlSession.data(for: pollRequest)
            guard let http = response as? HTTPURLResponse else {
                throw Error.invalidResponse
            }

            // 403/404 = authorization_pending per Codex's device endpoint.
            if http.statusCode == 403 || http.statusCode == 404 {
                continue
            }

            // Some server states include an explicit error string.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String
            {
                if error == "authorization_pending" {
                    continue
                }
                if error == "slow_down" {
                    try await Task.sleep(nanoseconds: UInt64(clampedInterval + 5) * 1_000_000_000)
                    continue
                }
                if error == "expired_token" || error == "access_denied" {
                    throw Error.timedOut
                }
                // Unknown error in body — fall through and treat as failure below.
            }

            guard (200 ..< 300).contains(http.statusCode) else {
                throw Error.requestFailed(status: http.statusCode, body: Self.responseBodyString(data))
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let authorizationCode = json["authorization_code"] as? String,
                  let codeVerifier = json["code_verifier"] as? String,
                  !authorizationCode.isEmpty, !codeVerifier.isEmpty
            else {
                throw Error.invalidResponse
            }

            return try await self.exchangeCode(
                authorizationCode: authorizationCode,
                codeVerifier: codeVerifier)
        }
    }

    private func exchangeCode(
        authorizationCode: String,
        codeVerifier: String) async throws -> CodexOAuthCredentials
    {
        let url = Self.authBaseURL.appendingPathComponent("/oauth/token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Self.formURLEncodedBody([
            "grant_type": "authorization_code",
            "code": authorizationCode,
            "redirect_uri": Self.redirectURI,
            "client_id": Self.clientID,
            "code_verifier": codeVerifier,
        ])

        let (data, response) = try await self.urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw Error.requestFailed(status: http.statusCode, body: Self.responseBodyString(data))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty
        else {
            throw Error.missingTokens
        }
        let refreshToken = (json["refresh_token"] as? String) ?? ""
        let idToken = json["id_token"] as? String
        let accountID = Self.extractChatGPTAccountID(idToken: idToken, accessToken: accessToken)

        return CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountId: accountID,
            lastRefresh: Date())
    }

    // MARK: - Helpers (internal for testability)

    static func verificationURL(userCode: String) -> URL {
        var components = URLComponents(
            url: Self.authBaseURL.appendingPathComponent("/codex/device"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user_code", value: userCode)]
        return components.url ?? Self.authBaseURL
    }

    /// Decodes the polling interval, tolerating servers that return it as
    /// an Int, Double, or String. Always clamps to at least 5 seconds.
    static func decodeInterval(_ raw: Any?) -> Int {
        let decoded: Int = {
            if let int = raw as? Int { return int }
            if let double = raw as? Double { return Int(double) }
            if let string = raw as? String, let int = Int(string) { return int }
            if let string = raw as? String, let double = Double(string) { return Int(double) }
            return 5
        }()
        return max(decoded, 5)
    }

    /// Extracts `chatgpt_account_id` from a JWT (id_token preferred,
    /// access_token fallback). Checks top-level first, then the nested
    /// `https://api.openai.com/auth` claim used by ChatGPT tokens.
    /// Returns nil when absent — callers must tolerate missing IDs.
    static func extractChatGPTAccountID(idToken: String?, accessToken: String) -> String? {
        for token in [idToken, accessToken].compactMap({ $0 }) {
            if let id = self.chatGPTAccountID(fromJWT: token) {
                return id
            }
        }
        return nil
    }

    private static func chatGPTAccountID(fromJWT token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        guard let payloadData = self.base64URLDecode(String(segments[1])) else { return nil }
        guard let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        if let id = (payload["chatgpt_account_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty
        {
            return id
        }
        if let auth = payload["https://api.openai.com/auth"] as? [String: Any],
           let id = (auth["chatgpt_account_id"] as? String)?
               .trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty
        {
            return id
        }
        return nil
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: normalized)
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

    private static func responseBodyString(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
