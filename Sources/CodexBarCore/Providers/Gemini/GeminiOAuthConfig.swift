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

    /// Test-injectable environment view so suites can override OAuth knobs without
    /// mutating process-wide env (which races parallel Gemini suites).
    public struct EnvironmentValues: Sendable, Equatable {
        public var clientID: String?
        public var clientSecret: String?
        public var oauth2JSPath: String?

        public init(clientID: String? = nil, clientSecret: String? = nil, oauth2JSPath: String? = nil) {
            self.clientID = clientID
            self.clientSecret = clientSecret
            self.oauth2JSPath = oauth2JSPath
        }

        public static func fromProcessEnvironment(
            _ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self
        {
            Self(
                clientID: environment["GEMINI_OAUTH_CLIENT_ID"],
                clientSecret: environment["GEMINI_OAUTH_CLIENT_SECRET"],
                oauth2JSPath: environment["GEMINI_OAUTH2_JS_PATH"])
        }
    }

    @TaskLocal public static var environmentOverride: EnvironmentValues?

    public static var currentEnvironment: EnvironmentValues {
        self.environmentOverride ?? .fromProcessEnvironment()
    }

    public static var configuredClientID: String? {
        self.currentEnvironment.clientID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    public static var configuredClientSecret: String? {
        self.currentEnvironment.clientSecret?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    public static var configuredOAuth2JSPath: String? {
        self.currentEnvironment.oauth2JSPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
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
