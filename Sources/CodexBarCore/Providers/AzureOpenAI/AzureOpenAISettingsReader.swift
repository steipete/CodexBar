import Foundation

public enum AzureOpenAISettingsReader {
    public static let apiKeyEnvironmentKey = "AZURE_OPENAI_API_KEY"
    public static let endpointEnvironmentKey = "AZURE_OPENAI_ENDPOINT"
    public static let deploymentNameEnvironmentKey = "AZURE_OPENAI_DEPLOYMENT_NAME"
    public static let apiVersionEnvironmentKey = "AZURE_OPENAI_API_VERSION"
    public static let defaultAPIVersion = "2024-10-21"

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func endpoint(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let rawEndpoint = self.cleaned(environment[self.endpointEnvironmentKey]) else { return nil }
        return self.endpointURL(from: rawEndpoint)
    }

    public static func deploymentName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleaned(environment[self.deploymentNameEnvironmentKey])
    }

    public static func apiVersion(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        self.cleaned(environment[self.apiVersionEnvironmentKey]) ?? self.defaultAPIVersion
    }

    public static func endpointURL(from rawEndpoint: String) -> URL? {
        let trimmed = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme),
              let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            return nil
        }
        return url
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

public enum AzureOpenAISettingsError: LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case missingEndpoint
    case missingDeploymentName
    case invalidEndpoint

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Azure OpenAI API key not configured. Set AZURE_OPENAI_API_KEY or configure an API key in Settings."
        case .missingEndpoint:
            "Azure OpenAI endpoint not configured. Set AZURE_OPENAI_ENDPOINT or configure an endpoint in Settings."
        case .missingDeploymentName:
            "Azure OpenAI deployment not configured. Set AZURE_OPENAI_DEPLOYMENT_NAME or configure a deployment " +
                "in Settings."
        case .invalidEndpoint:
            "Azure OpenAI endpoint is invalid."
        }
    }
}
