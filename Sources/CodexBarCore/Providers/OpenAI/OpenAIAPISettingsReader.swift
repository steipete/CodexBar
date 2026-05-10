import Foundation

public enum OpenAIAPISettingsReader {
    public static let apiKeyEnvironmentKey = "OPENAI_API_KEY"
    public static let apiKeyEnvironmentKeys = [
        Self.apiKeyEnvironmentKey,
    ]

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for key in self.apiKeyEnvironmentKeys {
            if let token = self.cleaned(environment[key]) { return token }
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
            value.removeFirst()
            value.removeLast()
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public enum OpenAIAPISettingsError: LocalizedError, Sendable {
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "OpenAI API key not configured. Set OPENAI_API_KEY or configure an API key in Settings."
        }
    }
}
