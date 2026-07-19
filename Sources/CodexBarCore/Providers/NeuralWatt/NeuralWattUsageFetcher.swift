import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Response models

public struct NeuralWattBalance: Codable, Sendable, Equatable {
    public let creditsRemainingUSD: Double?
    public let totalCreditsUSD: Double?
    public let creditsUsedUSD: Double?
    public let accountingMethod: String?

    private enum CodingKeys: String, CodingKey {
        case creditsRemainingUSD = "credits_remaining_usd"
        case totalCreditsUSD = "total_credits_usd"
        case creditsUsedUSD = "credits_used_usd"
        case accountingMethod = "accounting_method"
    }
}

public struct NeuralWattUsagePeriod: Codable, Sendable, Equatable {
    public let costUSD: Double?
    public let requests: Int?
    public let tokens: Int?
    public let energyKWh: Double?

    private enum CodingKeys: String, CodingKey {
        case costUSD = "cost_usd"
        case requests
        case tokens
        case energyKWh = "energy_kwh"
    }
}

public struct NeuralWattUsage: Codable, Sendable, Equatable {
    public let lifetime: NeuralWattUsagePeriod?
    public let currentMonth: NeuralWattUsagePeriod?

    private enum CodingKeys: String, CodingKey {
        case lifetime
        case currentMonth = "current_month"
    }
}

public struct NeuralWattLimits: Codable, Sendable, Equatable {
    public let overageLimitUSD: Double?
    public let rateLimitTier: String?

    private enum CodingKeys: String, CodingKey {
        case overageLimitUSD = "overage_limit_usd"
        case rateLimitTier = "rate_limit_tier"
    }
}

public struct NeuralWattSubscription: Codable, Sendable, Equatable {
    public let plan: String?
    public let status: String?
    public let billingInterval: String?
    public let currentPeriodStart: Date?
    public let currentPeriodEnd: Date?
    public let autoRenew: Bool?
    public let kwhIncluded: Double?
    public let kwhUsed: Double?
    public let kwhRemaining: Double?
    public let inOverage: Bool?

    private enum CodingKeys: String, CodingKey {
        case plan
        case status
        case billingInterval = "billing_interval"
        case currentPeriodStart = "current_period_start"
        case currentPeriodEnd = "current_period_end"
        case autoRenew = "auto_renew"
        case kwhIncluded = "kwh_included"
        case kwhUsed = "kwh_used"
        case kwhRemaining = "kwh_remaining"
        case inOverage = "in_overage"
    }
}

public struct NeuralWattKeyAllowance: Codable, Sendable, Equatable {
    public let limitUSD: Double?
    public let period: String?
    public let spentUSD: Double?
    public let remainingUSD: Double?
    public let blocked: Bool?

    private enum CodingKeys: String, CodingKey {
        case limitUSD = "limit_usd"
        case period
        case spentUSD = "spent_usd"
        case remainingUSD = "remaining_usd"
        case blocked
    }
}

public struct NeuralWattKey: Codable, Sendable, Equatable {
    public let name: String?
    public let allowance: NeuralWattKeyAllowance?
}

public struct NeuralWattQuotaResponse: Decodable, Sendable {
    public let snapshotAt: String?
    public let balance: NeuralWattBalance?
    public let usage: NeuralWattUsage?
    public let limits: NeuralWattLimits?
    public let subscription: NeuralWattSubscription?
    public let key: NeuralWattKey?

    private enum CodingKeys: String, CodingKey {
        case snapshotAt = "snapshot_at"
        case balance
        case usage
        case limits
        case subscription
        case key
    }

    private init(
        snapshotAt: String?,
        balance: NeuralWattBalance?,
        usage: NeuralWattUsage?,
        limits: NeuralWattLimits?,
        subscription: NeuralWattSubscription?,
        key: NeuralWattKey?)
    {
        self.snapshotAt = snapshotAt
        self.balance = balance
        self.usage = usage
        self.limits = limits
        self.subscription = subscription
        self.key = key
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.snapshotAt = try container.decodeIfPresent(String.self, forKey: .snapshotAt)
        self.balance = try container.decodeIfPresent(NeuralWattBalance.self, forKey: .balance)
        self.usage = try container.decodeIfPresent(NeuralWattUsage.self, forKey: .usage)
        self.limits = try container.decodeIfPresent(NeuralWattLimits.self, forKey: .limits)
        // `subscription` is documented as always-present: object when active, `null` otherwise.
        self.subscription = try container.decodeIfPresent(NeuralWattSubscription.self, forKey: .subscription)
        self.key = try container.decodeIfPresent(NeuralWattKey.self, forKey: .key)
    }
}

// MARK: - Snapshot

public struct NeuralWattUsageSnapshot: Codable, Sendable, Equatable {
    public let creditsRemainingUSD: Double?
    public let totalCreditsUSD: Double?
    public let creditsUsedUSD: Double?
    public let accountingMethod: String?
    public let currentMonthCostUSD: Double?
    public let currentMonthEnergyKWh: Double?
    public let subscription: NeuralWattSubscription?
    public let keyAllowance: NeuralWattKeyAllowance?
    public let rateLimitTier: String?
    public let updatedAt: Date

    public init(
        creditsRemainingUSD: Double?,
        totalCreditsUSD: Double?,
        creditsUsedUSD: Double?,
        accountingMethod: String?,
        currentMonthCostUSD: Double?,
        currentMonthEnergyKWh: Double?,
        subscription: NeuralWattSubscription?,
        keyAllowance: NeuralWattKeyAllowance?,
        rateLimitTier: String?,
        updatedAt: Date)
    {
        self.creditsRemainingUSD = creditsRemainingUSD
        self.totalCreditsUSD = totalCreditsUSD
        self.creditsUsedUSD = creditsUsedUSD
        self.accountingMethod = accountingMethod
        self.currentMonthCostUSD = currentMonthCostUSD
        self.currentMonthEnergyKWh = currentMonthEnergyKWh
        self.subscription = subscription
        self.keyAllowance = keyAllowance
        self.rateLimitTier = rateLimitTier
        self.updatedAt = updatedAt
    }

    public var creditUsedPercent: Double {
        if self.hasKnownZeroRemainingBalance {
            return 100
        }
        guard let used = self.effectiveUsedCredits, let total = self.effectiveTotalCredits, total > 0 else {
            return 0
        }
        return min(100, max(0, used / total * 100))
    }

    private var hasKnownZeroRemainingBalance: Bool {
        Self.validNonNegative(self.creditsRemainingUSD) == 0 && self.effectiveTotalCredits == nil
    }

    public var effectiveRemainingCredits: Double? {
        if let remaining = Self.validNonNegative(self.creditsRemainingUSD) { return remaining }
        guard let total = self.effectiveTotalCredits, let used = self.effectiveUsedCredits else { return nil }
        return max(0, total - used)
    }

    public var effectiveTotalCredits: Double? {
        if let total = Self.validPositive(self.totalCreditsUSD) { return total }
        guard let remaining = Self.validNonNegative(self.creditsRemainingUSD),
              let used = Self.validNonNegative(self.creditsUsedUSD)
        else { return nil }
        let total = remaining + used
        return total > 0 ? total : nil
    }

    public var effectiveUsedCredits: Double? {
        if let used = Self.validNonNegative(self.creditsUsedUSD) { return used }
        guard let total = Self.validPositive(self.totalCreditsUSD),
              let remaining = Self.validNonNegative(self.creditsRemainingUSD)
        else { return nil }
        return max(0, total - remaining)
    }

    public var keyAllowanceUsedPercent: Double? {
        if self.keyAllowance?.blocked == true { return 100 }
        guard let spent = self.keyAllowance?.spentUSD, let limit = self.keyAllowance?.limitUSD, limit > 0 else {
            return nil
        }
        return min(100, max(0, spent / limit * 100))
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let subscriptionWindow = self.subscriptionRateWindow
        var extras: [NamedRateWindow] = []
        if let percent = self.keyAllowanceUsedPercent, let allowance = self.keyAllowance {
            let periodTitle = (allowance.period ?? "allowance").capitalized
            extras.append(NamedRateWindow(
                id: "key-allowance",
                title: "Key \(periodTitle)",
                window: RateWindow(
                    usedPercent: percent,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: nil)))
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .neuralwatt,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: self.displayLoginMethod)

        return UsageSnapshot(
            primary: subscriptionWindow,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: extras.isEmpty ? nil : extras,
            providerCost: self.prepaidBalance,
            subscriptionRenewsAt: self.subscription?.autoRenew == false ? nil : subscriptionWindow?.resetsAt,
            updatedAt: self.updatedAt,
            identity: identity,
            dataConfidence: .exact)
    }

    private var subscriptionRateWindow: RateWindow? {
        guard let total = self.effectiveSubscriptionTotalKWh,
              let used = self.effectiveSubscriptionUsedKWh
        else { return nil }
        let minutes: Int? = if let start = self.subscription?.currentPeriodStart,
                               let end = self.subscription?.currentPeriodEnd,
                               end > start
        {
            max(1, Int(end.timeIntervalSince(start) / 60))
        } else {
            nil
        }
        return RateWindow(
            usedPercent: min(100, max(0, used / total * 100)),
            windowMinutes: minutes,
            resetsAt: self.subscription?.currentPeriodEnd,
            resetDescription: "\(Self.formatKWh(used)) / \(Self.formatKWh(total)) kWh")
    }

    private var effectiveSubscriptionTotalKWh: Double? {
        if let included = Self.validPositive(self.subscription?.kwhIncluded) { return included }
        guard let used = Self.validNonNegative(self.subscription?.kwhUsed),
              let remaining = Self.validNonNegative(self.subscription?.kwhRemaining)
        else { return nil }
        let total = used + remaining
        return total > 0 ? total : nil
    }

    private var effectiveSubscriptionUsedKWh: Double? {
        if let used = Self.validNonNegative(self.subscription?.kwhUsed) { return used }
        guard let total = self.effectiveSubscriptionTotalKWh,
              let remaining = Self.validNonNegative(self.subscription?.kwhRemaining)
        else { return nil }
        return max(0, total - remaining)
    }

    private var prepaidBalance: ProviderCostSnapshot? {
        guard let remaining = self.effectiveRemainingCredits else { return nil }
        return ProviderCostSnapshot(
            used: remaining,
            limit: 0,
            currencyCode: "USD",
            period: "Neuralwatt prepaid balance",
            updatedAt: self.updatedAt)
    }

    private var displayLoginMethod: String? {
        if let plan = self.subscription?.plan?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty {
            return "\(plan.replacingOccurrences(of: "_", with: " ").capitalized) plan"
        }
        if let method = self.accountingMethod, !method.isEmpty {
            return method.capitalized
        }
        return nil
    }

    fileprivate static func validNonNegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    fileprivate static func validPositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func formatKWh(_ value: Double) -> String {
        let digits = value.rounded() == value ? 0 : 2
        return String(format: "%.*f", digits, value)
    }
}

// MARK: - Errors

public enum NeuralWattUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Neuralwatt API key. Set apiKey in the CodexBar config file or NEURALWATT_API_KEY."
        case let .networkError(message):
            "Neuralwatt network error: \(message)"
        case let .apiError(message):
            "Neuralwatt API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Neuralwatt response: \(message)"
        }
    }
}

// MARK: - Fetcher

public struct NeuralWattUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.neuralWattUsage)
    private static let timeoutSeconds: TimeInterval = 15

    public static func fetchUsage(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        retryPolicy: ProviderHTTPRetryPolicy = .transientIdempotent) async throws -> NeuralWattUsageSnapshot
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NeuralWattUsageError.missingCredentials
        }
        try NeuralWattSettingsReader.validateEndpointOverrides(environment: environment)

        let url = Self.quotaURL(baseURL: NeuralWattSettingsReader.apiURL(environment: environment))
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request, retryPolicy: retryPolicy)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw NeuralWattUsageError.networkError(error.localizedDescription)
        }

        switch response.statusCode {
        case 200:
            return try Self.parseSnapshot(data: response.data, updatedAt: Date())
        case 401, 403:
            throw NeuralWattUsageError.missingCredentials
        default:
            Self.log.error("Neuralwatt API returned \(response.statusCode)")
            throw NeuralWattUsageError.apiError("HTTP \(response.statusCode)")
        }
    }

    static func _parseSnapshotForTesting(_ data: Data, updatedAt: Date) throws -> NeuralWattUsageSnapshot {
        try self.parseSnapshot(data: data, updatedAt: updatedAt)
    }

    private static func parseSnapshot(data: Data, updatedAt: Date) throws -> NeuralWattUsageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeISO8601Date)
        let decoded: NeuralWattQuotaResponse
        do {
            decoded = try decoder.decode(NeuralWattQuotaResponse.self, from: data)
        } catch {
            throw NeuralWattUsageError.parseFailed(error.localizedDescription)
        }

        guard let balance = decoded.balance else {
            throw NeuralWattUsageError.parseFailed("Missing Neuralwatt balance object")
        }
        guard NeuralWattUsageSnapshot.validNonNegative(balance.creditsRemainingUSD) != nil ||
            NeuralWattUsageSnapshot.validNonNegative(balance.creditsUsedUSD) != nil ||
            NeuralWattUsageSnapshot.validPositive(balance.totalCreditsUSD) != nil
        else {
            throw NeuralWattUsageError.parseFailed("Missing Neuralwatt credit balance fields")
        }

        return NeuralWattUsageSnapshot(
            creditsRemainingUSD: balance.creditsRemainingUSD,
            totalCreditsUSD: balance.totalCreditsUSD,
            creditsUsedUSD: balance.creditsUsedUSD,
            accountingMethod: balance.accountingMethod,
            currentMonthCostUSD: decoded.usage?.currentMonth?.costUSD,
            currentMonthEnergyKWh: decoded.usage?.currentMonth?.energyKWh,
            subscription: decoded.subscription,
            keyAllowance: decoded.key?.allowance,
            rateLimitTier: decoded.limits?.rateLimitTier,
            updatedAt: updatedAt)
    }

    private static func decodeISO8601Date(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        if let date = standardFormatter.date(from: value) {
            return date
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid ISO8601 date: \(value)")
    }

    private static func quotaURL(baseURL: URL) -> URL {
        var url = baseURL
        let pathComponents = url.path.split(separator: "/")
        if pathComponents.last == "v1" {
            url.append(path: "quota")
        } else {
            url.append(path: "v1/quota")
        }
        return url
    }
}
