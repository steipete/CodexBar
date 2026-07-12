import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum Sub2APIUsageError: LocalizedError, Equatable, Sendable {
    case missingCredentials
    case missingBaseURL
    case invalidCredentials
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing sub2api API key. Add a group API key in Settings or set SUB2API_API_KEY."
        case .missingBaseURL:
            "Missing or invalid sub2api base URL. Add one in Settings or set SUB2API_BASE_URL."
        case .invalidCredentials:
            "sub2api rejected the API key. Check that the key is active and assigned to a group."
        case let .apiError(statusCode):
            "sub2api API returned HTTP \(statusCode)."
        case let .parseFailed(message):
            "Could not parse sub2api usage: \(message)"
        }
    }
}

public struct Sub2APIUsageDetails: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case keyQuota
        case subscription
        case wallet
        case unknown
    }

    public struct Totals: Codable, Sendable, Equatable {
        public let requests: Int
        public let totalTokens: Int
        public let actualCostUSD: Double

        public init(requests: Int, totalTokens: Int, actualCostUSD: Double) {
            self.requests = requests
            self.totalTokens = totalTokens
            self.actualCostUSD = actualCostUSD
        }
    }

    public let kind: Kind
    public let balance: Double?
    public let unit: String
    public let today: Totals?
    public let total: Totals?

    public init(kind: Kind, balance: Double?, unit: String, today: Totals?, total: Totals?) {
        self.kind = kind
        self.balance = balance
        self.unit = unit
        self.today = today
        self.total = total
    }
}

public struct Sub2APIUsageSnapshot: Sendable, Equatable {
    public struct Quota: Sendable, Equatable {
        public let limit: Double
        public let used: Double
        public let remaining: Double
        public let unit: String
    }

    public struct RateLimit: Sendable, Equatable {
        public let window: String
        public let limit: Double
        public let used: Double
        public let remaining: Double
        public let resetAt: Date?
    }

    public struct Subscription: Sendable, Equatable {
        public let dailyUsageUSD: Double
        public let weeklyUsageUSD: Double
        public let monthlyUsageUSD: Double
        public let dailyLimitUSD: Double?
        public let weeklyLimitUSD: Double?
        public let monthlyLimitUSD: Double?
        public let expiresAt: Date?
    }

    public struct UsageTotals: Sendable, Equatable {
        public let requests: Int
        public let totalTokens: Int
        public let actualCostUSD: Double
    }

    public let mode: String
    public let isValid: Bool
    public let status: String?
    public let planName: String?
    public let remaining: Double?
    public let unit: String
    public let balance: Double?
    public let quota: Quota?
    public let rateLimits: [RateLimit]
    public let subscription: Subscription?
    public let todayUsage: UsageTotals?
    public let totalUsage: UsageTotals?
    public let expiresAt: Date?
    public let updatedAt: Date

    public func toUsageSnapshot() -> UsageSnapshot {
        let subscription = self.subscription
        let kind: Sub2APIUsageDetails.Kind = if subscription != nil {
            .subscription
        } else if self.quota != nil || !self.rateLimits.isEmpty {
            .keyQuota
        } else if self.balance != nil {
            .wallet
        } else {
            .unknown
        }
        let subscriptionWindows = subscription.map { subscription in
            [
                Self.rateWindow(
                    usage: subscription.dailyUsageUSD,
                    limit: subscription.dailyLimitUSD,
                    windowMinutes: 24 * 60),
                Self.rateWindow(
                    usage: subscription.weeklyUsageUSD,
                    limit: subscription.weeklyLimitUSD,
                    windowMinutes: 7 * 24 * 60),
                Self.rateWindow(
                    usage: subscription.monthlyUsageUSD,
                    limit: subscription.monthlyLimitUSD,
                    windowMinutes: 30 * 24 * 60),
            ]
        }
        let primary = subscriptionWindows?[0] ?? self.quota.map(Self.quotaWindow)
        let secondary = subscriptionWindows?[1]
        let tertiary = subscriptionWindows?[2]
        let namedWindows = self.rateLimits.map { rateLimit in
            NamedRateWindow(
                id: rateLimit.window,
                title: Self.rateLimitTitle(rateLimit.window),
                window: RateWindow(
                    usedPercent: Self.usedPercent(usage: rateLimit.used, limit: rateLimit.limit),
                    windowMinutes: Self.windowMinutes(rateLimit.window),
                    resetsAt: rateLimit.resetAt,
                    resetDescription: Self.amountDescription(used: rateLimit.used, limit: rateLimit.limit)))
        }
        let usageDetails = Sub2APIUsageDetails(
            kind: kind,
            balance: self.balance,
            unit: self.unit,
            today: self.todayUsage.map {
                Sub2APIUsageDetails.Totals(
                    requests: $0.requests,
                    totalTokens: $0.totalTokens,
                    actualCostUSD: $0.actualCostUSD)
            },
            total: self.totalUsage.map {
                Sub2APIUsageDetails.Totals(
                    requests: $0.requests,
                    totalTokens: $0.totalTokens,
                    actualCostUSD: $0.actualCostUSD)
            })

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extraRateWindows: namedWindows.isEmpty ? nil : namedWindows,
            sub2APIUsage: usageDetails,
            subscriptionExpiresAt: subscription?.expiresAt ?? self.expiresAt,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .sub2api,
                accountEmail: nil,
                accountOrganization: self.planName,
                loginMethod: self.planName),
            dataConfidence: .exact)
    }

    private static func quotaWindow(_ quota: Quota) -> RateWindow {
        RateWindow(
            usedPercent: self.usedPercent(usage: quota.used, limit: quota.limit),
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: self.amountDescription(used: quota.used, limit: quota.limit, unit: quota.unit))
    }

    private static func rateWindow(usage: Double, limit: Double?, windowMinutes: Int) -> RateWindow? {
        guard let limit, limit > 0 else { return nil }
        return RateWindow(
            usedPercent: self.usedPercent(usage: usage, limit: limit),
            windowMinutes: windowMinutes,
            resetsAt: nil,
            resetDescription: self.amountDescription(used: usage, limit: limit))
    }

    private static func usedPercent(usage: Double, limit: Double) -> Double {
        guard limit > 0 else { return 0 }
        return min(100, max(0, usage / limit * 100))
    }

    private static func amountDescription(used: Double, limit: Double, unit: String = "USD") -> String {
        "\(self.currencyString(used, unit: unit)) / \(self.currencyString(limit, unit: unit))"
    }

    private static func currencyString(_ value: Double, unit: String) -> String {
        unit.uppercased() == "USD" ? UsageFormatter.usdString(value) : String(format: "%.2f %@", value, unit)
    }

    private static func windowMinutes(_ window: String) -> Int? {
        switch window.lowercased() {
        case "5h": 5 * 60
        case "1d": 24 * 60
        case "7d": 7 * 24 * 60
        default: nil
        }
    }

    private static func rateLimitTitle(_ window: String) -> String {
        switch window.lowercased() {
        case "5h": "5 hour limit"
        case "1d": "Daily limit"
        case "7d": "7 day limit"
        default: "\(window) limit"
        }
    }
}

private struct Sub2APIUsageResponse: Decodable {
    struct Quota: Decodable {
        let limit: Double
        let used: Double
        let remaining: Double
        let unit: String?
    }

    struct RateLimit: Decodable {
        let window: String
        let limit: Double
        let used: Double
        let remaining: Double
        let resetAt: String?

        private enum CodingKeys: String, CodingKey {
            case window
            case limit
            case used
            case remaining
            case resetAt = "reset_at"
        }
    }

    struct Subscription: Decodable {
        let dailyUsageUSD: Double?
        let weeklyUsageUSD: Double?
        let monthlyUsageUSD: Double?
        let dailyLimitUSD: Double?
        let weeklyLimitUSD: Double?
        let monthlyLimitUSD: Double?
        let expiresAt: String?

        private enum CodingKeys: String, CodingKey {
            case dailyUsageUSD = "daily_usage_usd"
            case weeklyUsageUSD = "weekly_usage_usd"
            case monthlyUsageUSD = "monthly_usage_usd"
            case dailyLimitUSD = "daily_limit_usd"
            case weeklyLimitUSD = "weekly_limit_usd"
            case monthlyLimitUSD = "monthly_limit_usd"
            case expiresAt = "expires_at"
        }
    }

    struct Usage: Decodable {
        struct Totals: Decodable {
            let requests: Int?
            let totalTokens: Int?
            let actualCost: Double?

            private enum CodingKeys: String, CodingKey {
                case requests
                case totalTokens = "total_tokens"
                case actualCost = "actual_cost"
            }
        }

        let today: Totals?
        let total: Totals?
    }

    let mode: String?
    let isValid: Bool?
    let status: String?
    let planName: String?
    let remaining: Double?
    let unit: String?
    let balance: Double?
    let quota: Quota?
    let rateLimits: [RateLimit]?
    let subscription: Subscription?
    let usage: Usage?
    let expiresAt: String?

    private enum CodingKeys: String, CodingKey {
        case mode
        case isValid
        case status
        case planName
        case remaining
        case unit
        case balance
        case quota
        case rateLimits = "rate_limits"
        case subscription
        case usage
        case expiresAt = "expires_at"
    }
}

public struct Sub2APIUsageFetcher: Sendable {
    public init() {}

    public static func fetchUsage(
        apiKey: String,
        baseURL: URL,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: Duration = .seconds(15),
        updatedAt: Date = Date()) async throws -> Sub2APIUsageSnapshot
    {
        let cleanedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedAPIKey.isEmpty else { throw Sub2APIUsageError.missingCredentials }

        var request = URLRequest(url: self.usageRequestURL(baseURL: baseURL))
        request.httpMethod = "GET"
        request.setValue("Bearer \(cleanedAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let responseTask = Task {
            try await transport.response(for: request)
        }
        let response: ProviderHTTPResponse = switch await BoundedTaskJoin(sourceTask: responseTask)
            .value(joinGrace: timeout)
        {
        case let .value(response): response
        case let .failure(error): throw error
        case .timedOut: throw URLError(.timedOut)
        }
        switch response.statusCode {
        case 200..<300:
            let snapshot = try self.parseSnapshot(data: response.data, updatedAt: updatedAt)
            guard snapshot.isValid else { throw Sub2APIUsageError.invalidCredentials }
            return snapshot
        case 401, 403:
            throw Sub2APIUsageError.invalidCredentials
        default:
            throw Sub2APIUsageError.apiError(response.statusCode)
        }
    }

    public static func _parseSnapshotForTesting(_ data: Data, updatedAt: Date) throws -> Sub2APIUsageSnapshot {
        try self.parseSnapshot(data: data, updatedAt: updatedAt)
    }

    public static func _usageURLForTesting(baseURL: URL) -> URL {
        self.usageURL(baseURL: baseURL)
    }

    private static func usageURL(baseURL: URL) -> URL {
        let components = baseURL.path.split(separator: "/")
        if components.suffix(2) == ["v1", "usage"] {
            return baseURL
        }
        if components.last == "v1" {
            return baseURL.appendingPathComponent("usage")
        }
        return baseURL.appendingPathComponent("v1/usage")
    }

    private static func usageRequestURL(baseURL: URL) -> URL {
        let url = self.usageURL(baseURL: baseURL)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = [
            URLQueryItem(name: "days", value: "30"),
            URLQueryItem(name: "timezone", value: TimeZone.current.identifier),
        ]
        return components.url ?? url
    }

    private static func parseSnapshot(data: Data, updatedAt: Date) throws -> Sub2APIUsageSnapshot {
        do {
            let response = try JSONDecoder().decode(Sub2APIUsageResponse.self, from: data)
            let unit = response.unit ?? response.quota?.unit ?? "USD"
            return Sub2APIUsageSnapshot(
                mode: response.mode ?? "unknown",
                isValid: response.isValid ?? true,
                status: response.status,
                planName: response.planName,
                remaining: response.remaining,
                unit: unit,
                balance: response.balance,
                quota: response.quota.map {
                    Sub2APIUsageSnapshot.Quota(
                        limit: $0.limit,
                        used: $0.used,
                        remaining: $0.remaining,
                        unit: $0.unit ?? unit)
                },
                rateLimits: (response.rateLimits ?? []).map {
                    Sub2APIUsageSnapshot.RateLimit(
                        window: $0.window,
                        limit: $0.limit,
                        used: $0.used,
                        remaining: $0.remaining,
                        resetAt: self.parseDate($0.resetAt))
                },
                subscription: response.subscription.map {
                    Sub2APIUsageSnapshot.Subscription(
                        dailyUsageUSD: $0.dailyUsageUSD ?? 0,
                        weeklyUsageUSD: $0.weeklyUsageUSD ?? 0,
                        monthlyUsageUSD: $0.monthlyUsageUSD ?? 0,
                        dailyLimitUSD: $0.dailyLimitUSD,
                        weeklyLimitUSD: $0.weeklyLimitUSD,
                        monthlyLimitUSD: $0.monthlyLimitUSD,
                        expiresAt: self.parseDate($0.expiresAt))
                },
                todayUsage: self.usageTotals(response.usage?.today),
                totalUsage: self.usageTotals(response.usage?.total),
                expiresAt: self.parseDate(response.expiresAt),
                updatedAt: updatedAt)
        } catch let error as Sub2APIUsageError {
            throw error
        } catch {
            throw Sub2APIUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func usageTotals(_ totals: Sub2APIUsageResponse.Usage.Totals?)
        -> Sub2APIUsageSnapshot.UsageTotals?
    {
        guard let totals else { return nil }
        return Sub2APIUsageSnapshot.UsageTotals(
            requests: totals.requests ?? 0,
            totalTokens: totals.totalTokens ?? 0,
            actualCostUSD: totals.actualCost ?? 0)
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
