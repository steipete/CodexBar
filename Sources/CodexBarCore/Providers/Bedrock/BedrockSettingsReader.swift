import Foundation

public enum BedrockAuthMode: String, Codable, Sendable, CaseIterable {
    case keys
    case profile
}

public enum BedrockSettingsReader {
    public static let accessKeyIDKey = "AWS_ACCESS_KEY_ID"
    public static let secretAccessKeyKey = "AWS_SECRET_ACCESS_KEY"
    public static let sessionTokenKey = "AWS_SESSION_TOKEN"
    public static let regionKeys = ["AWS_REGION", "AWS_DEFAULT_REGION"]
    public static let budgetKey = "CODEXBAR_BEDROCK_BUDGET"
    public static let apiURLKey = "CODEXBAR_BEDROCK_API_URL"
    public static let cloudWatchAPIURLKey = "CODEXBAR_BEDROCK_CLOUDWATCH_API_URL"
    public static let profileKey = "AWS_PROFILE"
    public static let authModeKey = "CODEXBAR_BEDROCK_AUTH_MODE"
    public static let defaultRegion = "us-east-1"

    public static func accessKeyID(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        SettingsValue.cleaned(environment[self.accessKeyIDKey])
    }

    public static func secretAccessKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.cleaned(environment[self.secretAccessKeyKey])
    }

    public static func sessionToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.cleaned(environment[self.sessionTokenKey])
    }

    public static func region(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        for key in self.regionKeys {
            if let value = SettingsValue.cleaned(environment[key]) {
                return value
            }
        }
        return self.defaultRegion
    }

    public static func budget(environment: [String: String] = ProcessInfo.processInfo.environment) -> Double? {
        guard let raw = SettingsValue.cleaned(environment[self.budgetKey]),
              let value = Double(raw),
              value > 0
        else {
            return nil
        }
        return value
    }

    public static func profile(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.cleaned(environment[self.profileKey])
    }

    public static func authMode(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> BedrockAuthMode
    {
        if let raw = SettingsValue.cleaned(environment[self.authModeKey])?.lowercased(),
           let mode = BedrockAuthMode(rawValue: raw)
        {
            return mode
        }
        if self.profile(environment: environment) != nil,
           !self.hasStaticKeys(environment: environment)
        {
            return .profile
        }
        return .keys
    }

    static func hasStaticKeys(environment: [String: String]) -> Bool {
        self.accessKeyID(environment: environment) != nil &&
            self.secretAccessKey(environment: environment) != nil
    }

    public static func hasCredentials(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        switch self.authMode(environment: environment) {
        case .keys:
            self.hasStaticKeys(environment: environment)
        case .profile:
            self.profile(environment: environment) != nil
        }
    }
}
