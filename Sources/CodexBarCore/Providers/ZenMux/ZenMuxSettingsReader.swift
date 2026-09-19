import Foundation

public enum ZenMuxSettingsReader {
    public static let managementAPIKeyEnvironmentKey = "ZENMUX_MANAGEMENT_API_KEY"

    public static func managementAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.cleaned(environment[self.managementAPIKeyEnvironmentKey])
    }
}
