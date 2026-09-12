import Foundation

public struct StepFunSettingsReader: Sendable {
    public static let usernameEnvironmentKey = "STEPFUN_USERNAME"
    public static let passwordEnvironmentKey = "STEPFUN_PASSWORD"
    public static let tokenEnvironmentKey = "STEPFUN_TOKEN"

    public static func username(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.cleaned(environment[self.usernameEnvironmentKey])
    }

    public static func password(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.cleaned(environment[self.passwordEnvironmentKey])
    }

    public static func token(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.cleaned(environment[self.tokenEnvironmentKey])
    }
}
