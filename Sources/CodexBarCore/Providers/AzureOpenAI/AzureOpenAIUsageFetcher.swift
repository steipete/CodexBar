import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AzureOpenAIUsageSnapshot: Codable, Sendable, Equatable {
    public let endpointHost: String
    public let deploymentName: String
    public let model: String?
    public let apiVersion: String
    public let updatedAt: Date

    public init(
        endpointHost: String,
        deploymentName: String,
        model: String?,
        apiVersion: String,
        updatedAt: Date)
    {
        self.endpointHost = endpointHost
        self.deploymentName = deploymentName
        self.model = model
        self.apiVersion = apiVersion
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let detail = Self.detailText(deploymentName: self.deploymentName, model: self.model)
        return UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: detail),
            secondary: nil,
            tertiary: nil,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .azureopenai,
                accountEmail: nil,
                accountOrganization: self.endpointHost,
                loginMethod: "Deployment: \(self.deploymentName)"))
    }

    private static func detailText(deploymentName: String, model: String?) -> String {
        let cleanedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cleanedModel, !cleanedModel.isEmpty else {
            return "Deployment: \(deploymentName)"
        }
        return "Deployment: \(deploymentName) · Model: \(cleanedModel)"
    }
}

public enum AzureOpenAIUsageError: LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case missingEndpoint
    case missingDeploymentName
    case invalidEndpointOverride(String)
    case invalidURL
    case networkError(String)
    case apiError(statusCode: Int, message: String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            AzureOpenAISettingsError.missingAPIKey.errorDescription
        case .missingEndpoint:
            AzureOpenAISettingsError.missingEndpoint.errorDescription
        case .missingDeploymentName:
            AzureOpenAISettingsError.missingDeploymentName.errorDescription
        case let .invalidEndpointOverride(key):
            AzureOpenAISettingsError.invalidEndpointOverride(key).errorDescription
        case .invalidURL:
            "Azure OpenAI validation URL is invalid."
        case let .networkError(message):
            "Azure OpenAI network error: \(message)"
        case let .apiError(statusCode, message):
            if message.isEmpty {
                "Azure OpenAI API error: HTTP \(statusCode)"
            } else {
                "Azure OpenAI API error: HTTP \(statusCode): \(message)"
            }
        case let .parseFailed(message):
            "Azure OpenAI response parse error: \(message)"
        }
    }
}

private struct AzureOpenAIChatCompletionResponse: Decodable {
    let model: String?
}

public enum AzureOpenAIUsageFetcher {
    private static let timeoutSeconds: TimeInterval = 20
    private static let maxErrorBodyLength = 240

    public static func fetchUsage(
        apiKey: String,
        endpoint: URL,
        deploymentName: String,
        apiVersion: String = AzureOpenAISettingsReader.defaultAPIVersion,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        updatedAt: Date = Date()) async throws -> AzureOpenAIUsageSnapshot
    {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let deploymentName = deploymentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiVersion = apiVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw AzureOpenAIUsageError.missingAPIKey }
        guard !deploymentName.isEmpty else { throw AzureOpenAIUsageError.missingDeploymentName }
        guard let endpoint = ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: endpoint.absoluteString) else {
            throw AzureOpenAIUsageError.invalidEndpointOverride(AzureOpenAISettingsReader.endpointEnvironmentKey)
        }
        let effectiveAPIVersion = apiVersion.isEmpty ? AzureOpenAISettingsReader.defaultAPIVersion : apiVersion

        var request = try URLRequest(url: self.chatCompletionsURL(
            endpoint: endpoint,
            deploymentName: deploymentName,
            apiVersion: effectiveAPIVersion))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeoutSeconds
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try self.validationRequestBody(
            deploymentName: deploymentName,
            apiVersion: effectiveAPIVersion)

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch {
            throw AzureOpenAIUsageError.networkError(error.localizedDescription)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw AzureOpenAIUsageError.apiError(
                statusCode: response.statusCode,
                message: self.responseSummary(response.data))
        }

        let model: String?
        do {
            model = try JSONDecoder().decode(AzureOpenAIChatCompletionResponse.self, from: response.data).model
        } catch {
            throw AzureOpenAIUsageError.parseFailed(error.localizedDescription)
        }

        return AzureOpenAIUsageSnapshot(
            endpointHost: endpoint.host ?? endpoint.absoluteString,
            deploymentName: deploymentName,
            model: model,
            apiVersion: effectiveAPIVersion,
            updatedAt: updatedAt)
    }

    public static func _chatCompletionsURLForTesting(
        endpoint: URL,
        deploymentName: String,
        apiVersion: String) throws -> URL
    {
        try self.chatCompletionsURL(endpoint: endpoint, deploymentName: deploymentName, apiVersion: apiVersion)
    }

    private static func chatCompletionsURL(
        endpoint: URL,
        deploymentName: String,
        apiVersion: String) throws -> URL
    {
        if self.usesV1API(apiVersion) {
            let base = self.apiRoot(endpoint: endpoint, pathComponents: ["openai", "v1"])
                .appendingPathComponent("chat")
                .appendingPathComponent("completions")
            guard let url = URLComponents(url: base, resolvingAgainstBaseURL: false)?.url else {
                throw AzureOpenAIUsageError.invalidURL
            }
            return url
        }

        let base = self.apiRoot(endpoint: endpoint, pathComponents: ["openai"])
            .appendingPathComponent("deployments")
            .appendingPathComponent(deploymentName)
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw AzureOpenAIUsageError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "api-version", value: apiVersion)]
        guard let url = components.url else { throw AzureOpenAIUsageError.invalidURL }
        return url
    }

    private static func apiRoot(endpoint: URL, pathComponents expectedComponents: [String]) -> URL {
        let existingComponents = endpoint.pathComponents
            .filter { $0 != "/" }
            .map { $0.lowercased() }
        let expectedComponents = expectedComponents.map { $0.lowercased() }
        let sharedCount = stride(
            from: min(existingComponents.count, expectedComponents.count),
            through: 0,
            by: -1)
            .first { count in
                count == 0 || Array(existingComponents.suffix(count)) == Array(expectedComponents.prefix(count))
            } ?? 0
        return expectedComponents.dropFirst(sharedCount).reduce(endpoint) { url, component in
            url.appendingPathComponent(component)
        }
    }

    private static func validationRequestBody(
        deploymentName: String,
        apiVersion: String) throws -> Data
    {
        var payload: [String: Any] = [
            "messages": [
                ["role": "user", "content": "ping"],
            ],
        ]
        if self.usesV1API(apiVersion) {
            payload["model"] = deploymentName
            payload["max_completion_tokens"] = 1
        } else {
            payload["max_tokens"] = 1
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private static func usesV1API(_ apiVersion: String) -> Bool {
        apiVersion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "v1"
    }

    private static func responseSummary(_ data: Data) -> String {
        guard let body = String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !body.isEmpty
        else {
            return ""
        }
        guard body.count > Self.maxErrorBodyLength else { return body }
        let index = body.index(body.startIndex, offsetBy: Self.maxErrorBodyLength)
        return "\(body[..<index])… [truncated]"
    }
}
