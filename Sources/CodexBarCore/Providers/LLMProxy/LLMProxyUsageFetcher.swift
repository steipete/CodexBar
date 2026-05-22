import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LLMProxyUsageError: LocalizedError, Sendable {
    case missingCredentials
    case missingBaseURL
    case invalidURL
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing LLM Proxy API key. Set apiKey in ~/.codexbar/config.json or LLM_PROXY_API_KEY."
        case .missingBaseURL:
            "Missing LLM Proxy base URL. Set enterpriseHost in ~/.codexbar/config.json or LLM_PROXY_BASE_URL."
        case .invalidURL:
            "LLM Proxy URL is invalid."
        case let .apiError(message):
            "LLM Proxy API error: \(message)"
        case let .parseFailed(message):
            "LLM Proxy parse error: \(message)"
        }
    }
}

public struct LLMProxyUsageSnapshot: Codable, Sendable, Equatable {
    public let providerCount: Int
    public let credentialCount: Int
    public let activeCredentialCount: Int
    public let exhaustedCredentialCount: Int
    public let totalRequests: Int
    public let totalTokens: Int
    public let approximateCostUSD: Double?
    public let minimumRemainingPercent: Double?
    public let nextResetAt: Date?
    public let topProviders: [ProviderSummary]
    public let updatedAt: Date

    public struct ProviderSummary: Codable, Sendable, Equatable {
        public let name: String
        public let requests: Int
        public let tokens: Int
        public let approximateCostUSD: Double?
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let used = self.minimumRemainingPercent.map { max(0, min(100, 100 - $0)) }
        let windows = self.topProviders.prefix(3).map { provider in
            NamedRateWindow(
                id: provider.name,
                title: provider.name,
                window: RateWindow(
                    usedPercent: 0,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: Self.providerSummaryText(provider)))
        }
        return UsageSnapshot(
            primary: used.map {
                RateWindow(
                    usedPercent: $0,
                    windowMinutes: nil,
                    resetsAt: self.nextResetAt,
                    resetDescription: nil)
            },
            secondary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "\(Self.formatInteger(self.totalRequests)) requests"),
            tertiary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "\(Self.formatInteger(self.totalTokens)) tokens"),
            extraRateWindows: windows.isEmpty ? nil : Array(windows),
            providerCost: self.approximateCostUSD.map {
                ProviderCostSnapshot(
                    used: $0,
                    limit: 0,
                    currencyCode: "USD",
                    period: "Approx. spend",
                    resetsAt: self.nextResetAt,
                    updatedAt: self.updatedAt)
            },
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .llmproxy,
                accountEmail: nil,
                accountOrganization: "\(self.activeCredentialCount)/\(self.credentialCount) active keys",
                loginMethod: "quota-stats"))
    }

    private static func providerSummaryText(_ provider: ProviderSummary) -> String {
        var pieces = [
            "\(Self.formatInteger(provider.requests)) req",
            "\(Self.formatInteger(provider.tokens)) tok",
        ]
        if let cost = provider.approximateCostUSD {
            pieces.append(UsageFormatter.usdString(cost))
        }
        return pieces.joined(separator: " · ")
    }

    private static func formatInteger(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private struct LLMProxyQuotaStatsResponse: Decodable {
    struct ProviderStats: Decodable {
        struct Tokens: Decodable {
            let inputCached: Int?
            let inputUncached: Int?
            let output: Int?

            private enum CodingKeys: String, CodingKey {
                case inputCached = "input_cached"
                case inputUncached = "input_uncached"
                case output
            }
        }

        struct QuotaGroup: Decodable {
            let remainingPercent: Double?
            let resetTime: String?

            private enum CodingKeys: String, CodingKey {
                case remainingPercent = "remaining_percent"
                case resetTime = "reset_time"
            }
        }

        let credentialCount: Int?
        let activeCount: Int?
        let exhaustedCount: Int?
        let totalRequests: Int?
        let tokens: Tokens?
        let approximateCost: Double?
        let quotaGroups: [QuotaGroup]?

        private enum CodingKeys: String, CodingKey {
            case credentialCount = "credential_count"
            case activeCount = "active_count"
            case exhaustedCount = "exhausted_count"
            case totalRequests = "total_requests"
            case tokens
            case approximateCost = "approx_cost"
            case quotaGroups = "quota_groups"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.credentialCount = try container.decodeIfPresent(Int.self, forKey: .credentialCount)
            self.activeCount = try container.decodeIfPresent(Int.self, forKey: .activeCount)
            self.exhaustedCount = try container.decodeIfPresent(Int.self, forKey: .exhaustedCount)
            self.totalRequests = try container.decodeIfPresent(Int.self, forKey: .totalRequests)
            self.tokens = try container.decodeIfPresent(Tokens.self, forKey: .tokens)
            self.approximateCost = try container.decodeIfPresent(Double.self, forKey: .approximateCost)
            self.quotaGroups = Self.decodeQuotaGroups(from: container)
        }

        private static func decodeQuotaGroups(from container: KeyedDecodingContainer<CodingKeys>)
            -> [QuotaGroup]?
        {
            if let groups = try? container.decodeIfPresent([QuotaGroup].self, forKey: .quotaGroups) {
                return groups
            }
            let keyedGroups = try? container.decodeIfPresent(
                [String: QuotaGroup].self,
                forKey: .quotaGroups)
            return keyedGroups?.values.sorted { lhs, rhs in
                (lhs.remainingPercent ?? .infinity) < (rhs.remainingPercent ?? .infinity)
            }
        }
    }

    struct Summary: Decodable {
        let totalRequests: Int?
        let approximateCost: Double?
        let totalTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case totalRequests = "total_requests"
            case approximateCost = "approx_cost"
            case totalTokens = "total_tokens"
        }
    }

    let providers: [String: ProviderStats]
    let summary: Summary?
}

public struct LLMProxyUsageFetcher: Sendable {
    public init() {}

    public static func fetchUsage(
        apiKey: String,
        baseURL: URL,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        updatedAt: Date = Date()) async throws -> LLMProxyUsageSnapshot
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMProxyUsageError.missingCredentials
        }
        let url = self.quotaStatsURL(baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw LLMProxyUsageError.apiError("HTTP \(response.statusCode): \(Self.responseSummary(response.data))")
        }
        return try self.parseSnapshot(data: response.data, updatedAt: updatedAt)
    }

    public static func _parseSnapshotForTesting(_ data: Data, updatedAt: Date) throws -> LLMProxyUsageSnapshot {
        try self.parseSnapshot(data: data, updatedAt: updatedAt)
    }

    public static func _quotaStatsURLForTesting(baseURL: URL) -> URL {
        self.quotaStatsURL(baseURL: baseURL)
    }

    private static func quotaStatsURL(baseURL: URL) -> URL {
        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let versionedBaseURL = path.split(separator: "/").last == "v1"
            ? baseURL
            : baseURL.appendingPathComponent("v1")
        return versionedBaseURL.appendingPathComponent("quota-stats")
    }

    private static func parseSnapshot(data: Data, updatedAt: Date) throws -> LLMProxyUsageSnapshot {
        do {
            let decoded = try JSONDecoder().decode(LLMProxyQuotaStatsResponse.self, from: data)
            let providers = decoded.providers
            let summaries = providers.map { name, stats in
                LLMProxyUsageSnapshot.ProviderSummary(
                    name: name,
                    requests: stats.totalRequests ?? 0,
                    tokens: Self.tokenTotal(stats.tokens),
                    approximateCostUSD: stats.approximateCost)
            }.sorted { lhs, rhs in
                if lhs.requests != rhs.requests { return lhs.requests > rhs.requests }
                return lhs.name < rhs.name
            }
            let requests = decoded.summary?.totalRequests ?? summaries.reduce(0) { $0 + $1.requests }
            let tokens = decoded.summary?.totalTokens ?? summaries.reduce(0) { $0 + $1.tokens }
            let cost = decoded.summary?.approximateCost ?? {
                let sum = summaries.compactMap(\.approximateCostUSD).reduce(0, +)
                return sum > 0 ? sum : nil
            }()

            let quotaGroups = providers.values.flatMap { $0.quotaGroups ?? [] }
            let minRemaining = quotaGroups.compactMap(\.remainingPercent).min()
            let reset = quotaGroups.compactMap { Self.parseDate($0.resetTime) }.min()

            return LLMProxyUsageSnapshot(
                providerCount: providers.count,
                credentialCount: providers.values.reduce(0) { $0 + ($1.credentialCount ?? 0) },
                activeCredentialCount: providers.values.reduce(0) { $0 + ($1.activeCount ?? 0) },
                exhaustedCredentialCount: providers.values.reduce(0) { $0 + ($1.exhaustedCount ?? 0) },
                totalRequests: requests,
                totalTokens: tokens,
                approximateCostUSD: cost,
                minimumRemainingPercent: minRemaining,
                nextResetAt: reset,
                topProviders: summaries,
                updatedAt: updatedAt)
        } catch let error as LLMProxyUsageError {
            throw error
        } catch {
            throw LLMProxyUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func tokenTotal(_ tokens: LLMProxyQuotaStatsResponse.ProviderStats.Tokens?) -> Int {
        (tokens?.inputCached ?? 0) + (tokens?.inputUncached ?? 0) + (tokens?.output ?? 0)
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let date = self.iso8601DateFormatter(fractionalSeconds: true).date(from: raw) {
            return date
        }
        return self.iso8601DateFormatter(fractionalSeconds: false).date(from: raw)
    }

    private static func iso8601DateFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        if fractionalSeconds {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }
        return formatter
    }

    private static func responseSummary(_ data: Data) -> String {
        String(bytes: data.prefix(500), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }
}
