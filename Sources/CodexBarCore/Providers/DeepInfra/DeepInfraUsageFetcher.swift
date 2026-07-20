import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DeepInfraChecklistResponse: Decodable, Sendable {
    public let stripeBalance: Double
    public let recent: Double
    public let limit: Double?
    public let suspended: Bool
    public let suspendReason: String?

    enum CodingKeys: String, CodingKey {
        case stripeBalance = "stripe_balance"
        case recent
        case limit
        case suspended
        case suspendReason = "suspend_reason"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stripeBalance = try container.decode(Double.self, forKey: .stripeBalance)
        self.recent = try container.decode(Double.self, forKey: .recent)
        self.limit = try container.decodeIfPresent(Double.self, forKey: .limit)
        self.suspended = try container.decodeIfPresent(Bool.self, forKey: .suspended) ?? false
        self.suspendReason = try container.decodeIfPresent(String.self, forKey: .suspendReason)
    }
}

public struct DeepInfraUsageResponse: Decodable, Sendable {
    public let months: [DeepInfraUsageMonth]
    public let initialMonth: String?

    enum CodingKeys: String, CodingKey {
        case months
        case initialMonth = "initial_month"
    }
}

public struct DeepInfraUsageMonth: Decodable, Sendable {
    public let period: String
    public let totalCostCents: Double

    enum CodingKeys: String, CodingKey {
        case period
        case totalCostCents = "total_cost"
    }
}

public struct DeepInfraUsageSnapshot: Sendable {
    public let availableBalanceUSD: Double
    public let amountOwedUSD: Double
    public let currentMonthCostUSD: Double
    public let recentCostUSD: Double
    public let spendingLimitUSD: Double?
    public let suspended: Bool
    public let suspendReason: String?
    public let updatedAt: Date

    public init(
        availableBalanceUSD: Double,
        amountOwedUSD: Double,
        currentMonthCostUSD: Double,
        recentCostUSD: Double,
        spendingLimitUSD: Double?,
        suspended: Bool,
        suspendReason: String?,
        updatedAt: Date)
    {
        self.availableBalanceUSD = availableBalanceUSD
        self.amountOwedUSD = amountOwedUSD
        self.currentMonthCostUSD = currentMonthCostUSD
        self.recentCostUSD = recentCostUSD
        self.spendingLimitUSD = spendingLimitUSD
        self.suspended = suspended
        self.suspendReason = suspendReason
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let usedPercent: Double = self.suspended || self.amountOwedUSD > 0 || self.availableBalanceUSD <= 0 ? 100 : 0

        let balanceText = if self.amountOwedUSD > 0 {
            "\(Self.usd(self.amountOwedUSD)) owed"
        } else {
            "\(Self.usd(self.availableBalanceUSD)) available"
        }
        let spendingText = "\(Self.usd(self.currentMonthCostUSD)) spent this month"
        let detail = if self.suspended {
            if let reason = self.suspendReason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                "Suspended: \(reason) · \(balanceText) · \(spendingText)"
            } else {
                "Suspended · \(balanceText) · \(spendingText)"
            }
        } else {
            "\(balanceText) · \(spendingText)"
        }

        let providerCost: ProviderCostSnapshot? = if let limit = self.spendingLimitUSD, limit > 0 {
            ProviderCostSnapshot(
                used: self.recentCostUSD,
                limit: limit,
                currencyCode: "USD",
                period: "Billing cycle",
                updatedAt: self.updatedAt)
        } else {
            nil
        }
        let identity = ProviderIdentitySnapshot(
            providerID: .deepinfra,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)

        return UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: detail),
            secondary: nil,
            providerCost: providerCost,
            updatedAt: self.updatedAt,
            identity: identity,
            dataConfidence: .exact)
    }

    private static func usd(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}

public enum DeepInfraUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing DeepInfra API key."
        case let .networkError(message):
            "DeepInfra network error: \(message)"
        case let .apiError(message):
            "DeepInfra API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse DeepInfra response: \(message)"
        }
    }
}

public struct DeepInfraUsageFetcher: Sendable {
    private static let checklistURL = URL(string: "https://api.deepinfra.com/payment/checklist?compute_owed=true")!
    private static let usageURL = URL(string: "https://api.deepinfra.com/payment/usage?from=current")!
    private static let timeoutSeconds: TimeInterval = 30
    /// The usage endpoint reports `total_cost` in cents; checklist monetary fields use USD.
    private static let centsPerDollar = 100.0

    public static func fetchUsage(apiKey: String) async throws -> DeepInfraUsageSnapshot {
        try await self.fetchUsage(apiKey: apiKey, transport: ProviderHTTPClient.shared, now: Date())
    }

    static func _fetchUsageForTesting(
        apiKey: String,
        transport: any ProviderHTTPTransport,
        now: Date = Date()) async throws -> DeepInfraUsageSnapshot
    {
        try await self.fetchUsage(apiKey: apiKey, transport: transport, now: now)
    }

    static func _parseSnapshotForTesting(
        checklistData: Data,
        usageData: Data,
        now: Date = Date()) throws -> DeepInfraUsageSnapshot
    {
        try self.parseSnapshot(checklistData: checklistData, usageData: usageData, now: now)
    }

    private static func fetchUsage(
        apiKey: String,
        transport: any ProviderHTTPTransport,
        now: Date) async throws -> DeepInfraUsageSnapshot
    {
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw DeepInfraUsageError.missingCredentials }

        do {
            let checklistResponse = try await transport.response(
                for: self.request(url: self.checklistURL, token: token),
                retryPolicy: .transientIdempotent)
            try self.validate(checklistResponse)

            let usageResponse = try await transport.response(
                for: self.request(url: self.usageURL, token: token),
                retryPolicy: .transientIdempotent)
            try self.validate(usageResponse)

            return try self.parseSnapshot(
                checklistData: checklistResponse.data,
                usageData: usageResponse.data,
                now: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DeepInfraUsageError {
            throw error
        } catch {
            throw DeepInfraUsageError.networkError(error.localizedDescription)
        }
    }

    private static func request(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = self.timeoutSeconds
        return request
    }

    private static func validate(_ response: ProviderHTTPResponse) throws {
        switch response.statusCode {
        case 200:
            return
        case 401:
            throw DeepInfraUsageError.apiError("API key rejected (HTTP 401).")
        case 403:
            throw DeepInfraUsageError.apiError("API key cannot access billing data (HTTP 403).")
        default:
            throw DeepInfraUsageError.apiError("HTTP \(response.statusCode)")
        }
    }

    private static func parseSnapshot(
        checklistData: Data,
        usageData: Data,
        now: Date) throws -> DeepInfraUsageSnapshot
    {
        do {
            let decoder = JSONDecoder()
            let checklist = try decoder.decode(DeepInfraChecklistResponse.self, from: checklistData)
            let usage = try decoder.decode(DeepInfraUsageResponse.self, from: usageData)
            let recentCost = max(0, checklist.recent)
            let currentMonthCost = usage.months.last
                .map { max(0, $0.totalCostCents / Self.centsPerDollar) }
                ?? recentCost
            let netBalance = checklist.stripeBalance + recentCost
            let limit = checklist.limit.flatMap { $0 > 0 ? $0 : nil }

            return DeepInfraUsageSnapshot(
                availableBalanceUSD: max(0, -netBalance),
                amountOwedUSD: max(0, netBalance),
                currentMonthCostUSD: currentMonthCost,
                recentCostUSD: recentCost,
                spendingLimitUSD: limit,
                suspended: checklist.suspended,
                suspendReason: checklist.suspendReason,
                updatedAt: now)
        } catch let error as DeepInfraUsageError {
            throw error
        } catch {
            throw DeepInfraUsageError.parseFailed(error.localizedDescription)
        }
    }
}
