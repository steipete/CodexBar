import Foundation

public struct DoubaoSettingsReader: Sendable {
    public static let apiKeyEnvironmentKeys = [
        "ARK_API_KEY",
        "VOLCENGINE_API_KEY",
        "DOUBAO_API_KEY",
    ]
    public static let accessKeyIDEnvironmentKeys = [
        "VOLCENGINE_ACCESS_KEY_ID",
        "VOLCENGINE_ACCESS_KEY",
        "VOLC_ACCESSKEY",
        "DOUBAO_ACCESS_KEY_ID",
    ]
    public static let secretAccessKeyEnvironmentKeys = [
        "VOLCENGINE_SECRET_ACCESS_KEY",
        "VOLCENGINE_SECRET_KEY",
        "VOLCENGINE_ACCESS_KEY_SECRET",
        "VOLC_SECRETKEY",
        "DOUBAO_SECRET_ACCESS_KEY",
    ]
    public static let regionEnvironmentKeys = [
        "VOLCENGINE_REGION",
        "VOLCENGINE_REGION_ID",
        "VOLC_REGION",
        "DOUBAO_REGION",
    ]
    public static let defaultRegion = "cn-beijing"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.firstValue(in: environment, keys: self.apiKeyEnvironmentKeys)
    }

    public static func accessKeyID(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.firstValue(in: environment, keys: self.accessKeyIDEnvironmentKeys)
    }

    public static func secretAccessKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.firstValue(in: environment, keys: self.secretAccessKeyEnvironmentKeys)
    }

    public static func region(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        self.firstValue(in: environment, keys: self.regionEnvironmentKeys) ?? self.defaultRegion
    }

    public static func codingPlanCredentials(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> DoubaoCodingPlanCredentials?
    {
        guard let accessKeyID = self.accessKeyID(environment: environment),
              let secretAccessKey = self.secretAccessKey(environment: environment)
        else {
            return nil
        }
        return DoubaoCodingPlanCredentials(
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            region: self.region(environment: environment))
    }

    private static func firstValue(in environment: [String: String], keys: [String]) -> String? {
        for key in keys {
            guard let cleaned = self.cleaned(environment[key]) else { continue }
            return cleaned
        }
        return nil
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
