import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ClawRouterUsageError: LocalizedError, Equatable, Sendable {
    case missingCredentials
    case invalidCredentials
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing ClawRouter API key. Add one in Settings or set CLAWROUTER_API_KEY."
        case .invalidCredentials:
            "ClawRouter rejected the API key. Check the key and its policy status."
        case let .apiError(statusCode):
            "ClawRouter API returned HTTP \(statusCode)."
        case let .parseFailed(message):
            "Could not parse ClawRouter usage: \(message)"
        }
    }
}

public struct ClawRouterUsageSnapshot: Codable, Sendable, Equatable {
    public struct ProviderSummary: Codable, Sendable, Equatable {
        public let provider: String
        public let requestCount: Int
        public let successCount: Int
        public let errorCount: Int
        public let totalTokens: Int
        public let actualCostUSD: Double
    }

    public let budgetConfigured: Bool
    public let budgetLedger: String
    public let budgetLimitUSD: Double?
    public let budgetSpentUSD: Double?
    public let budgetRemainingUSD: Double?
    public let budgetResetsAt: Date?
    public let requestCount: Int
    public let successCount: Int
    public let errorCount: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public let actualCostUSD: Double
    public let providers: [ProviderSummary]
    public let updatedAt: Date

    public func toUsageSnapshot() -> UsageSnapshot {
        let usedPercent: Double? = if let spent = self.budgetSpentUSD,
                                      let limit = self.budgetLimitUSD,
                                      limit > 0
        {
            min(100, max(0, spent / limit * 100))
        } else {
            nil
        }
        let providerCost: ProviderCostSnapshot? = if let spent = self.budgetSpentUSD,
                                                     let limit = self.budgetLimitUSD
        {
            ProviderCostSnapshot(
                used: spent,
                limit: limit,
                currencyCode: "USD",
                period: "This month",
                resetsAt: self.budgetResetsAt,
                updatedAt: self.updatedAt)
        } else if self.actualCostUSD > 0 {
            ProviderCostSnapshot(
                used: self.actualCostUSD,
                limit: 0,
                currencyCode: "USD",
                period: "This month",
                resetsAt: self.budgetResetsAt,
                updatedAt: self.updatedAt)
        } else {
            nil
        }

        return UsageSnapshot(
            primary: usedPercent.map {
                RateWindow(
                    usedPercent: $0,
                    windowMinutes: nil,
                    resetsAt: self.budgetResetsAt,
                    resetDescription: nil)
            },
            secondary: nil,
            providerCost: providerCost,
            clawRouterUsage: self,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .clawrouter,
                accountEmail: nil,
                accountOrganization: "\(self.providers.count) routed providers",
                loginMethod: self.budgetConfigured ? "Managed monthly budget" : "Unmetered"),
            dataConfidence: .exact)
    }
}

private struct ClawRouterUsageResponse: Decodable {
    struct Budget: Decodable {
        let configured: Bool
        let ledger: String
        let windowKey: String?
        let limitMicros: Int64?
        let spentMicros: Int64?
        let remainingMicros: Int64?
    }

    struct Usage: Decodable {
        struct Summary: Decodable {
            let requestCount: Int
            let successCount: Int
            let errorCount: Int
            let inputTokens: Int
            let outputTokens: Int
            let totalTokens: Int
            let actualCostMicros: Int64
        }

        struct Provider: Decodable {
            let provider: String
            let requestCount: Int
            let successCount: Int
            let errorCount: Int
            let totalTokens: Int
            let actualCostMicros: Int64
        }

        let summary: Summary
        let providers: [Provider]
    }

    let budget: Budget
    let usage: Usage
}

public enum ClawRouterUsageFetcher {
    public static func fetchUsage(
        apiKey: String,
        baseURL: URL,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        updatedAt: Date = Date()) async throws -> ClawRouterUsageSnapshot
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClawRouterUsageError.missingCredentials
        }
        var request = URLRequest(url: self.usageURL(baseURL: baseURL))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.response(for: request)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw ClawRouterUsageError.invalidCredentials
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ClawRouterUsageError.apiError(response.statusCode)
        }
        return try self.parseSnapshot(data: response.data, updatedAt: updatedAt)
    }

    public static func _parseSnapshotForTesting(
        _ data: Data,
        updatedAt: Date) throws -> ClawRouterUsageSnapshot
    {
        try self.parseSnapshot(data: data, updatedAt: updatedAt)
    }

    public static func _usageURLForTesting(baseURL: URL) -> URL {
        self.usageURL(baseURL: baseURL)
    }

    private static func usageURL(baseURL: URL) -> URL {
        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let versionedBaseURL = path.split(separator: "/").last == "v1"
            ? baseURL
            : baseURL.appendingPathComponent("v1")
        return versionedBaseURL.appendingPathComponent("usage")
    }

    private static func parseSnapshot(data: Data, updatedAt: Date) throws -> ClawRouterUsageSnapshot {
        do {
            let response = try JSONDecoder().decode(ClawRouterUsageResponse.self, from: data)
            return ClawRouterUsageSnapshot(
                budgetConfigured: response.budget.configured,
                budgetLedger: response.budget.ledger,
                budgetLimitUSD: self.dollars(response.budget.limitMicros),
                budgetSpentUSD: self.dollars(response.budget.spentMicros),
                budgetRemainingUSD: self.dollars(response.budget.remainingMicros),
                budgetResetsAt: self.nextMonthlyReset(windowKey: response.budget.windowKey),
                requestCount: response.usage.summary.requestCount,
                successCount: response.usage.summary.successCount,
                errorCount: response.usage.summary.errorCount,
                inputTokens: response.usage.summary.inputTokens,
                outputTokens: response.usage.summary.outputTokens,
                totalTokens: response.usage.summary.totalTokens,
                actualCostUSD: self.dollars(response.usage.summary.actualCostMicros),
                providers: response.usage.providers.map {
                    ClawRouterUsageSnapshot.ProviderSummary(
                        provider: $0.provider,
                        requestCount: $0.requestCount,
                        successCount: $0.successCount,
                        errorCount: $0.errorCount,
                        totalTokens: $0.totalTokens,
                        actualCostUSD: self.dollars($0.actualCostMicros))
                }.sorted {
                    if $0.actualCostUSD != $1.actualCostUSD { return $0.actualCostUSD > $1.actualCostUSD }
                    if $0.requestCount != $1.requestCount { return $0.requestCount > $1.requestCount }
                    return $0.provider < $1.provider
                },
                updatedAt: updatedAt)
        } catch let error as ClawRouterUsageError {
            throw error
        } catch {
            throw ClawRouterUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func dollars(_ micros: Int64?) -> Double? {
        micros.map(self.dollars)
    }

    private static func dollars(_ micros: Int64) -> Double {
        Double(micros) / 1_000_000
    }

    private static func nextMonthlyReset(windowKey: String?) -> Date? {
        guard let suffix = windowKey?.split(separator: "/").last else { return nil }
        let components = suffix.split(separator: "-")
        guard components.count == 2,
              let year = Int(components[0]),
              let month = Int(components[1]),
              (1...12).contains(month)
        else { return nil }

        var nextYear = year
        var nextMonth = month + 1
        if nextMonth == 13 {
            nextMonth = 1
            nextYear += 1
        }
        return DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: nextYear,
            month: nextMonth,
            day: 1).date
    }
}
