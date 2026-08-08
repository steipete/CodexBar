import Foundation

public struct DeepgramSettingsReader: Sendable {
    public static let apiKeyEnvironmentKey = "DEEPGRAM_API_KEY"
    public static let projectIDEnvironmentKey = "DEEPGRAM_PROJECT_ID"
    public static let apiURLEnvironmentKey = "DEEPGRAM_API_URL"
    public static let defaultAPIURL = URL(string: "https://api.deepgram.com/v1")!

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func projectID(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.projectIDEnvironmentKey])
    }

    public static func apiURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        guard let raw = self.cleaned(environment[self.apiURLEnvironmentKey]) else { return self.defaultAPIURL }
        return ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw) ?? self.defaultAPIURL
    }

    public static func validateEndpointOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard let raw = self.cleaned(environment[self.apiURLEnvironmentKey]) else { return }
        guard ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw) != nil else {
            throw DeepgramSettingsError.invalidEndpointOverride(self.apiURLEnvironmentKey)
        }
    }

    private static func cleaned(_ raw: String?) -> String? {
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
