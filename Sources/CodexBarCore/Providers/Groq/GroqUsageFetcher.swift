import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GroqUsageError: LocalizedError, Sendable {
    case missingCredentials
    case invalidURL
    case accessDenied(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Groq API key. Set apiKey in ~/.codexbar/config.json or GROQ_API_KEY."
        case .invalidURL:
            "Groq metrics URL is invalid."
        case let .accessDenied(message):
            "Groq metrics access denied: \(message)"
        case let .apiError(message):
            "Groq metrics API error: \(message)"
        case let .parseFailed(message):
            "Groq metrics parse error: \(message)"
        }
    }
}

public struct GroqUsageSnapshot: Codable, Sendable, Equatable {
    public let requestRatePerSecond: Double
    public let inputTokenRatePerSecond: Double
    public let outputTokenRatePerSecond: Double
    public let promptCacheHitRatePerSecond: Double
    public let updatedAt: Date

    public init(
        requestRatePerSecond: Double,
        inputTokenRatePerSecond: Double,
        outputTokenRatePerSecond: Double,
        promptCacheHitRatePerSecond: Double = 0,
        updatedAt: Date)
    {
        self.requestRatePerSecond = requestRatePerSecond
        self.inputTokenRatePerSecond = inputTokenRatePerSecond
        self.outputTokenRatePerSecond = outputTokenRatePerSecond
        self.promptCacheHitRatePerSecond = promptCacheHitRatePerSecond
        self.updatedAt = updatedAt
    }

    public var requestsPerMinute: Double {
        self.requestRatePerSecond * 60
    }

    public var tokensPerMinute: Double {
        (self.inputTokenRatePerSecond + self.outputTokenRatePerSecond) * 60
    }

    public var cacheHitsPerMinute: Double {
        self.promptCacheHitRatePerSecond * 60
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 5,
                resetsAt: nil,
                resetDescription: "\(Self.formatDecimal(self.requestsPerMinute)) req/min"),
            secondary: RateWindow(
                usedPercent: 0,
                windowMinutes: 5,
                resetsAt: nil,
                resetDescription: "\(Self.formatDecimal(self.tokensPerMinute)) tok/min"),
            tertiary: self.promptCacheHitRatePerSecond > 0 ? RateWindow(
                usedPercent: 0,
                windowMinutes: 5,
                resetsAt: nil,
                resetDescription: "\(Self.formatDecimal(self.cacheHitsPerMinute)) cache/min") : nil,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .groq,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Prometheus metrics"))
    }

    static func formatDecimal(_ value: Double) -> String {
        if value >= 100 {
            return String(format: "%.0f", value)
        }
        if value >= 10 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.2f", value)
    }
}

private struct GroqPrometheusResponse: Decodable {
    struct Payload: Decodable {
        let result: [Series]
    }

    struct Series: Decodable {
        let value: [PrometheusValue]?
    }

    enum PrometheusValue: Decodable {
        case number(Double)
        case string(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                self = .number(number)
                return
            }
            self = try .string(container.decode(String.self))
        }

        var doubleValue: Double? {
            switch self {
            case let .number(number):
                number
            case let .string(text):
                Double(text)
            }
        }
    }

    let status: String
    let data: Payload?
    let error: String?
}

public struct GroqUsageFetcher: Sendable {
    public init() {}

    public static func fetchUsage(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        updatedAt: Date = Date()) async throws -> GroqUsageSnapshot
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GroqUsageError.missingCredentials
        }
        try GroqSettingsReader.validateEndpointOverrides(environment: environment)
        let baseURL = GroqSettingsReader.apiURL(environment: environment)
            .appendingPathComponent("metrics")
            .appendingPathComponent("prometheus")

        async let requests = Self.queryScalar(
            query: "sum(model_project_id_status_code:requests:rate5m)",
            apiKey: apiKey,
            baseURL: baseURL,
            transport: transport)
        async let inputTokens = Self.queryScalar(
            query: "sum(model_project_id:tokens_in:rate5m)",
            apiKey: apiKey,
            baseURL: baseURL,
            transport: transport)
        async let outputTokens = Self.queryScalar(
            query: "sum(model_project_id:tokens_out:rate5m)",
            apiKey: apiKey,
            baseURL: baseURL,
            transport: transport)
        async let cacheHits = Self.queryScalar(
            query: "sum(model_project_id:prompt_cache_hits:rate5m)",
            apiKey: apiKey,
            baseURL: baseURL,
            transport: transport)

        return try await GroqUsageSnapshot(
            requestRatePerSecond: requests,
            inputTokenRatePerSecond: inputTokens,
            outputTokenRatePerSecond: outputTokens,
            promptCacheHitRatePerSecond: cacheHits,
            updatedAt: updatedAt)
    }

    public static func _parseScalarForTesting(_ data: Data) throws -> Double {
        try self.parseScalar(data: data)
    }

    private static func queryScalar(
        query: String,
        apiKey: String,
        baseURL: URL,
        transport: any ProviderHTTPTransport) async throws -> Double
    {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/query"),
            resolvingAgainstBaseURL: false)
        else { throw GroqUsageError.invalidURL }
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = components.url else { throw GroqUsageError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let summary = Self.responseSummary(response.data)
            if response.statusCode == 401 || response.statusCode == 403 {
                throw GroqUsageError.accessDenied(summary)
            }
            throw GroqUsageError.apiError("HTTP \(response.statusCode): \(summary)")
        }
        return try self.parseScalar(data: response.data)
    }

    private static func parseScalar(data: Data) throws -> Double {
        do {
            let decoded = try JSONDecoder().decode(GroqPrometheusResponse.self, from: data)
            guard decoded.status == "success" else {
                throw GroqUsageError.apiError(decoded.error ?? "query failed")
            }
            return decoded.data?.result.compactMap { series in
                series.value?.last?.doubleValue
            }.reduce(0, +) ?? 0
        } catch let error as GroqUsageError {
            throw error
        } catch {
            throw GroqUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func responseSummary(_ data: Data) -> String {
        String(bytes: data.prefix(500), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }
}
