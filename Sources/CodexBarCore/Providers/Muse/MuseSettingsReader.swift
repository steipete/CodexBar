import Foundation

public enum MuseSettingsReader {
    public static let apiKeyEnvironmentKeys = ["META_API_KEY", "MUSE_API_KEY"]
    public static let baseURLEnvironmentKey = "MUSE_BASE_URL"
    public static let defaultBaseURL = URL(string: "https://api.meta.ai/v1")!

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for key in self.apiKeyEnvironmentKeys {
            if let value = self.cleaned(environment[key]) {
                return value
            }
        }
        return nil
    }

    public static func baseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let raw = self.cleaned(environment[self.baseURLEnvironmentKey]),
           let url = URL(string: raw), url.scheme?.hasPrefix("http") == true
        {
            return url
        }
        return self.defaultBaseURL
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

public enum MuseUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidAPIKey
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Muse API key not found. Set META_API_KEY or add a token account for Muse, or run `muse login`."
        case .invalidAPIKey:
            "Muse API key was rejected. Run `muse login` or set a valid META_API_KEY."
        case let .networkError(message):
            message
        }
    }
}
