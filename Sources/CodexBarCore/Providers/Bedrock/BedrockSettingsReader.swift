import Foundation

/// Reads AWS Bedrock settings from environment variables and config.
public enum BedrockSettingsReader {
    /// Environment variable key for AWS access key ID.
    public static let accessKeyIDKey = "AWS_ACCESS_KEY_ID"
    /// Environment variable key for AWS secret access key.
    public static let secretAccessKeyKey = "AWS_SECRET_ACCESS_KEY"
    /// Environment variable key for optional session token (temporary credentials).
    public static let sessionTokenKey = "AWS_SESSION_TOKEN"
    /// Environment variable keys for AWS region (checked in order).
    public static let regionKeys = ["AWS_REGION", "AWS_DEFAULT_REGION"]
    /// Environment variable key for a user-defined monthly Bedrock budget (USD).
    public static let budgetKey = "CODEXBAR_BEDROCK_BUDGET"
    /// Environment variable key for overriding the Cost Explorer API endpoint.
    public static let apiURLKey = "CODEXBAR_BEDROCK_API_URL"

    /// The config-file API key env var used by `ProviderConfigEnvironment`.
    public static let apiKeyEnvKey = "AWS_ACCESS_KEY_ID"

    public static let defaultRegion = "us-east-1"

    /// Returns the AWS access key ID from environment if present and non-empty.
    public static func accessKeyID(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleaned(environment[self.accessKeyIDKey])
    }

    /// Returns the AWS secret access key from environment if present and non-empty.
    public static func secretAccessKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.secretAccessKeyKey])
    }

    /// Returns the optional session token from environment.
    public static func sessionToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.sessionTokenKey])
    }

    /// Returns the AWS region, checking `AWS_REGION` then `AWS_DEFAULT_REGION`, falling back to us-east-1.
    public static func region(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        for key in self.regionKeys {
            if let value = self.cleaned(environment[key]) {
                return value
            }
        }
        return self.defaultRegion
    }

    /// Returns the user-defined monthly Bedrock budget in USD, if set via environment.
    public static func budget(environment: [String: String] = ProcessInfo.processInfo.environment) -> Double? {
        guard let raw = self.cleaned(environment[self.budgetKey]),
              let value = Double(raw), value > 0
        else {
            return nil
        }
        return value
    }

    /// Returns true if valid AWS credentials are available in the environment.
    public static func hasCredentials(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        self.accessKeyID(environment: environment) != nil
            && self.secretAccessKey(environment: environment) != nil
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
