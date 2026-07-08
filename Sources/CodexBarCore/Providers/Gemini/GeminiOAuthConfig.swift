import Foundation

/// Gemini CLI OAuth client resolution helpers for token refresh.
/// Mirrors Antigravity's env override pattern.
public enum GeminiOAuthConfig: Sendable {
    public struct ClientCredentials: Sendable, Equatable {
        public let clientID: String
        public let clientSecret: String

        public init(clientID: String, clientSecret: String) {
            self.clientID = clientID
            self.clientSecret = clientSecret
        }
    }

    public static var configuredClientID: String? {
        let value = ProcessInfo.processInfo.environment["GEMINI_OAUTH_CLIENT_ID"]
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public static var configuredClientSecret: String? {
        let value = ProcessInfo.processInfo.environment["GEMINI_OAUTH_CLIENT_SECRET"]
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public static var configuredOAuth2JSPath: String? {
        let value = ProcessInfo.processInfo.environment["GEMINI_OAUTH2_JS_PATH"]
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public static func environmentClient() -> ClientCredentials? {
        guard let clientID = configuredClientID,
              let clientSecret = configuredClientSecret
        else {
            return nil
        }
        return ClientCredentials(clientID: clientID, clientSecret: clientSecret)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}
