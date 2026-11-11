import Foundation

/// Provider-owned key reader. The key is also projected into the plugin environment as `NANOGPT_API_KEY`,
/// so the bundled script receives one canonical secret name regardless of whether it came from
/// Settings, `NANOGPT_API_KEY`, or a stored token account.
public enum NanoGPTSettingsReader {
    /// Canonical environment key shared by the settings field, token accounts, and the plugin secret.
    public static let apiKeyEnvironmentKey = "NANOGPT_API_KEY"
    /// Printed in diagnose output so a pasted key is identified as a NanoGPT inference key.
    public static let apiKeyDebugLabel = "NanoGPT inference API key"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.first(in: environment, keys: [self.apiKeyEnvironmentKey])
    }
}
