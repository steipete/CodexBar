import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Wire DTOs (CrossModel returns integer micro units; 1 USD = 1_000_000 micro)

/// `GET /v1/credits` response.
struct CrossModelCreditsResponse: Decodable {
    let currency: String
    let balanceMicro: Int64
    let uncollectedMicro: Int64

    private enum CodingKeys: String, CodingKey {
        case currency
        case balanceMicro = "balance_micro"
        case uncollectedMicro = "uncollected_micro"
    }
}

/// One usage window from `GET /v1/usage`.
struct CrossModelUsageWindowDTO: Decodable {
    let costMicro: Int64
    let promptTokens: Int64
    let completionTokens: Int64
    let totalTokens: Int64
    let requestCount: Int64
    let successCount: Int64

    private enum CodingKeys: String, CodingKey {
        case costMicro = "cost_micro"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case requestCount = "request_count"
        case successCount = "success_count"
    }
}

/// `GET /v1/usage` response.
struct CrossModelUsageResponse: Decodable {
    let currency: String
    let daily: CrossModelUsageWindowDTO
    let weekly: CrossModelUsageWindowDTO
    let monthly: CrossModelUsageWindowDTO
}

// MARK: - Snapshot (USD-normalized, persisted in UsageSnapshot)

/// One usage window with cost converted to USD.
public struct CrossModelUsageWindow: Codable, Sendable, Equatable {
    public let costUSD: Double
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int
    public let requestCount: Int
    public let successCount: Int

    public init(
        costUSD: Double,
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int,
        requestCount: Int,
        successCount: Int)
    {
        self.costUSD = costUSD
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.requestCount = requestCount
        self.successCount = successCount
    }

    init(dto: CrossModelUsageWindowDTO) {
        self.costUSD = CrossModelUsageSnapshot.usd(dto.costMicro)
        self.promptTokens = Int(dto.promptTokens)
        self.completionTokens = Int(dto.completionTokens)
        self.totalTokens = Int(dto.totalTokens)
        self.requestCount = Int(dto.requestCount)
        self.successCount = Int(dto.successCount)
    }
}

/// Complete CrossModel usage snapshot: wallet balance plus UTC day/week/month spend.
public struct CrossModelUsageSnapshot: Codable, Sendable, Equatable {
    public let currency: String
    public let balanceUSD: Double
    public let uncollectedUSD: Double
    public let daily: CrossModelUsageWindow?
    public let weekly: CrossModelUsageWindow?
    public let monthly: CrossModelUsageWindow?
    public let updatedAt: Date

    public init(
        currency: String,
        balanceUSD: Double,
        uncollectedUSD: Double,
        daily: CrossModelUsageWindow?,
        weekly: CrossModelUsageWindow?,
        monthly: CrossModelUsageWindow?,
        updatedAt: Date)
    {
        self.currency = currency
        self.balanceUSD = balanceUSD
        self.uncollectedUSD = uncollectedUSD
        self.daily = daily
        self.weekly = weekly
        self.monthly = monthly
        self.updatedAt = updatedAt
    }

    static func usd(_ micro: Int64) -> Double {
        Double(micro) / 1_000_000.0
    }

    /// Formatted balance for identity display (e.g. "$8.06").
    public var balanceDisplay: String {
        String(format: "$%.2f", self.balanceUSD)
    }
}

extension CrossModelUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let identity = ProviderIdentitySnapshot(
            providerID: .crossmodel,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Balance: \(self.balanceDisplay)")

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            crossModelUsage: self,
            updatedAt: self.updatedAt,
            identity: identity,
            dataConfidence: .exact)
    }
}

// MARK: - Fetcher

/// Fetches balance + usage stats from the CrossModel API.
public struct CrossModelUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.crossModelUsage)
    private static let creditsRequestTimeoutSeconds: TimeInterval = 15
    private static let usageRequestTimeoutSeconds: TimeInterval = 3
    private static let maxErrorBodyLength = 240

    /// Fetches balance (required) and usage windows (best-effort) using the provided API key.
    public static func fetchUsage(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> CrossModelUsageSnapshot
    {
        guard !apiKey.isEmpty else {
            throw CrossModelUsageError.invalidCredentials
        }
        try CrossModelSettingsReader.validateEndpointOverrides(environment: environment)

        let baseURL = CrossModelSettingsReader.apiURL(environment: environment)
        let credits = try await self.fetchCredits(apiKey: apiKey, baseURL: baseURL, transport: transport)

        // Usage windows are best-effort: a slow or failing /usage call should not
        // block the balance the user came to see.
        let usage = try await self.fetchUsageWindows(apiKey: apiKey, baseURL: baseURL, transport: transport)

        return CrossModelUsageSnapshot(
            currency: credits.currency,
            balanceUSD: CrossModelUsageSnapshot.usd(credits.balanceMicro),
            uncollectedUSD: CrossModelUsageSnapshot.usd(credits.uncollectedMicro),
            daily: usage.map { CrossModelUsageWindow(dto: $0.daily) },
            weekly: usage.map { CrossModelUsageWindow(dto: $0.weekly) },
            monthly: usage.map { CrossModelUsageWindow(dto: $0.monthly) },
            updatedAt: Date())
    }

    private static func fetchCredits(
        apiKey: String,
        baseURL: URL,
        transport: any ProviderHTTPTransport) async throws -> CrossModelCreditsResponse
    {
        let url = baseURL.appendingPathComponent("credits")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.creditsRequestTimeoutSeconds

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            let summary = LogRedactor.redact(Self.sanitizedResponseBodySummary(response.data))
            Self.log.error("CrossModel /credits returned \(response.statusCode): \(summary)")
            if response.statusCode == 401 || response.statusCode == 403 {
                throw CrossModelUsageError.invalidCredentials
            }
            throw CrossModelUsageError.apiError("HTTP \(response.statusCode)")
        }

        do {
            return try JSONDecoder().decode(CrossModelCreditsResponse.self, from: response.data)
        } catch let error as DecodingError {
            Self.log.error("CrossModel /credits decode error: \(error.localizedDescription)")
            throw CrossModelUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func fetchUsageWindows(
        apiKey: String,
        baseURL: URL,
        transport: any ProviderHTTPTransport) async throws -> CrossModelUsageResponse?
    {
        let url = baseURL.appendingPathComponent("usage")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.usageRequestTimeoutSeconds

        do {
            let response = try await transport.response(for: request)
            guard response.statusCode == 200 else {
                Self.log.debug("CrossModel /usage enrichment returned \(response.statusCode)")
                return nil
            }
            return try JSONDecoder().decode(CrossModelUsageResponse.self, from: response.data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            Self.log.debug("Failed to fetch CrossModel /usage enrichment: \(error.localizedDescription)")
            return nil
        }
    }

    private static func sanitizedResponseBodySummary(_ data: Data) -> String {
        guard !data.isEmpty else { return "empty body" }
        guard let rawBody = String(bytes: data, encoding: .utf8) else {
            return "non-text body (\(data.count) bytes)"
        }

        let body = Self.redactSensitiveBodyContent(rawBody)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty else { return "non-text body (\(data.count) bytes)" }
        guard body.count > Self.maxErrorBodyLength else { return body }

        let index = body.index(body.startIndex, offsetBy: Self.maxErrorBodyLength)
        return "\(body[..<index])… [truncated]"
    }

    private static func redactSensitiveBodyContent(_ text: String) -> String {
        let replacements: [(String, String)] = [
            (#"(?i)(bearer\s+)[A-Za-z0-9._\-]+"#, "$1[REDACTED]"),
            (#"(?i)(cm-)[A-Za-z0-9._\-]+"#, "$1[REDACTED]"),
            (
                #"(?i)(\"(?:api_?key|authorization|token|access_token|refresh_token)\"\s*:\s*\")([^\"]+)(\")"#,
                "$1[REDACTED]$3"),
            (
                #"(?i)((?:api_?key|authorization|token|access_token|refresh_token)\s*[=:]\s*)([^,\s]+)"#,
                "$1[REDACTED]"),
        ]

        return replacements.reduce(text) { partial, replacement in
            partial.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression)
        }
    }

    #if DEBUG
    static func _sanitizedResponseBodySummaryForTesting(_ body: String) -> String {
        self.sanitizedResponseBodySummary(Data(body.utf8))
    }
    #endif
}

/// Errors that can occur during CrossModel usage fetching.
public enum CrossModelUsageError: LocalizedError, Sendable {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Invalid CrossModel API credentials"
        case let .networkError(message):
            "CrossModel network error: \(message)"
        case let .apiError(message):
            "CrossModel API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse CrossModel response: \(message)"
        }
    }
}
