import Foundation

public enum BedrockSettingsReader {
    public static let accessKeyIDKey = "AWS_ACCESS_KEY_ID"
    public static let secretAccessKeyKey = "AWS_SECRET_ACCESS_KEY"
    public static let sessionTokenKey = "AWS_SESSION_TOKEN"
    public static let regionKeys = ["AWS_REGION", "AWS_DEFAULT_REGION"]
    public static let budgetKey = "CODEXBAR_BEDROCK_BUDGET"
    public static let apiURLKey = "CODEXBAR_BEDROCK_API_URL"
    public static let defaultRegion = "us-east-1"

    public static func accessKeyID(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleaned(environment[self.accessKeyIDKey])
    }

    public static func secretAccessKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.secretAccessKeyKey])
    }

    public static func sessionToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.sessionTokenKey])
    }

    public static func region(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        for key in self.regionKeys {
            if let value = self.cleaned(environment[key]) {
                return value
            }
        }
        return self.defaultRegion
    }

    public static func budget(environment: [String: String] = ProcessInfo.processInfo.environment) -> Double? {
        guard let raw = self.cleaned(environment[self.budgetKey]),
              let value = Double(raw),
              value > 0
        else {
            return nil
        }
        return value
    }

    public static func hasCredentials(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        self.accessKeyID(environment: environment) != nil &&
            self.secretAccessKey(environment: environment) != nil
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
