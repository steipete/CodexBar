import Foundation

public struct StepFunSettingsReader: Sendable {
    public static let usernameEnvironmentKey = "STEPFUN_USERNAME"
    public static let passwordEnvironmentKey = "STEPFUN_PASSWORD"
    public static let tokenEnvironmentKey = "STEPFUN_TOKEN"

    public static func username(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.usernameEnvironmentKey])
    }

    public static func password(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.passwordEnvironmentKey])
    }

    public static func token(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.tokenEnvironmentKey])
    }

    private static func cleaned(_ raw: String?) -> String? {
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
