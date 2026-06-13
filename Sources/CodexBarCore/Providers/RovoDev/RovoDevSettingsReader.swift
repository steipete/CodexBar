import Foundation

public enum RovoDevSettingsReader {
    /// Environment variable for the Atlassian API token used to authenticate with the Rovo Dev credits API.
    public static let apiTokenEnvironmentKey = "ROVODEV_API_TOKEN"
    public static let emailEnvironmentKey = "ROVODEV_EMAIL"
    public static let apiURLEnvironmentKey = "ROVODEV_API_URL"

    /// Returns the API token from the environment (ROVODEV_API_TOKEN).
    public static func apiToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleaned(environment[self.apiTokenEnvironmentKey])
    }

    /// Returns the account email from the environment (ROVODEV_EMAIL).
    public static func email(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleaned(environment[self.emailEnvironmentKey])
    }

    /// Returns the base API URL (default: https://api.atlassian.com).
    public static func apiURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let url = self.validAPIURL(environment: environment) {
            return url
        }
        return URL(string: "https://api.atlassian.com")!
    }

    public static func validateEndpointOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard let raw = self.cleaned(environment[self.apiURLEnvironmentKey]) else { return }
        guard ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw) == nil else { return }
        throw RovoDevSettingsError.invalidEndpointOverride(self.apiURLEnvironmentKey)
    }

    /// Returns the billing site URL from ~/.rovodev/config.yml if available.
    public static func billingSiteURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let configURL = homeDirectory
            .appendingPathComponent(".rovodev", isDirectory: true)
            .appendingPathComponent("config.yml", isDirectory: false)
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        // Parse siteUrl from YAML: "siteUrl: https://..."
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("siteUrl:") {
                let value = trimmed.dropFirst("siteUrl:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty { return value }
            }
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

    private static func validAPIURL(environment: [String: String]) -> URL? {
        guard let raw = self.cleaned(environment[self.apiURLEnvironmentKey]) else { return nil }
        return ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw)
    }
}

public enum RovoDevSettingsError: LocalizedError, Sendable, Equatable {
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidEndpointOverride(key):
            "Rovo Dev endpoint override \(key) must use HTTPS or a bare host."
        }
    }
}
