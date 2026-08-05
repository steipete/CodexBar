import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct FireworksUsageSnapshot: Sendable {
    public let summary: FireworksUsageSummary

    public init(summary: FireworksUsageSummary) {
        self.summary = summary
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        self.summary.toUsageSnapshot()
    }
}

public struct FireworksUsageSummary: Sendable {
    /// Sum of rated line items from `GET /v1/accounts/{slug}/billing/summary` for the
    /// last 30 days. Fireworks exposes no credit-balance API, so spend is the only
    /// usable usage signal.
    public let last30DaysSpend: Double?
    public let currencyCode: String?
    public let updatedAt: Date

    public init(
        last30DaysSpend: Double?,
        currencyCode: String?,
        updatedAt: Date)
    {
        self.last30DaysSpend = last30DaysSpend
        self.currencyCode = currencyCode
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        // Fireworks is prepaid with no quota windows, so no RateWindows are synthesized.
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: self.last30DaysSpend.flatMap { spend in
                self.currencyCode.map { code in
                    ProviderCostSnapshot(
                        used: spend,
                        limit: 0,
                        currencyCode: code,
                        period: "Last 30 days",
                        updatedAt: self.updatedAt)
                }
            },
            updatedAt: self.updatedAt,
            identity: nil)
    }
}

public enum FireworksUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case missingAccountSlug
    case authenticationRejected
    case rateLimited
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Fireworks API key. Add one in Settings or set FIREWORKS_API_KEY."
        case .missingAccountSlug:
            "Missing Fireworks account slug. Set FIREWORKS_ACCOUNT_SLUG or the slug field in Settings."
        case .authenticationRejected:
            "Fireworks rejected the API key. Create a new key at app.fireworks.ai and update Settings."
        case .rateLimited:
            "Fireworks rate limit exceeded. Usage will refresh on the next cycle."
        case let .apiError(statusCode):
            "Fireworks billing API returned HTTP \(statusCode)."
        case let .parseFailed(message):
            "Could not parse Fireworks usage: \(message)"
        }
    }
}

public struct FireworksUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.provider(.fireworks, scope: "usage"))
    private static let timeoutSeconds: TimeInterval = 15
    /// Fireworks billing windows are tied to calendar days; a 30-day lookback matches the
    /// card's "Last 30 days" period.
    private static let lookbackDays = 30

    public static func fetchUsage(
        apiKey: String,
        accountSlug: String,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> FireworksUsageSnapshot
    {
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else {
            throw FireworksUsageError.missingCredentials
        }
        let cleanedSlug = accountSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSlug.isEmpty else {
            throw FireworksUsageError.missingAccountSlug
        }

        let startTime = now.addingTimeInterval(-TimeInterval(self.lookbackDays * 24 * 60 * 60))
        var request = URLRequest(
            url: Self.resolveSummaryURL(accountSlug: cleanedSlug, startTime: startTime, endTime: now))
        request.httpMethod = "GET"
        request.setValue("Bearer \(cleanedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch {
            throw error
        }

        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw FireworksUsageError.authenticationRejected
        case 429:
            throw FireworksUsageError.rateLimited
        default:
            Self.log.error("Fireworks API returned HTTP \(response.statusCode)")
            throw FireworksUsageError.apiError(response.statusCode)
        }

        let summary = try self.parseSummary(data: response.data, now: now)
        return FireworksUsageSnapshot(summary: summary)
    }

    /// `https://api.fireworks.ai/v1/accounts/<slug>/billing/summary` with an explicit
    /// 30-day `startTime`/`endTime` window.
    public static func resolveSummaryURL(
        accountSlug: String,
        startTime: Date? = nil,
        endTime: Date? = nil) -> URL
    {
        var components = URLComponents(
            string: "https://api.fireworks.ai/v1/accounts/\(accountSlug)/billing/summary")!
        var query: [URLQueryItem] = []
        if let startTime {
            query.append(URLQueryItem(name: "startTime", value: Self.isoString(startTime)))
        }
        if let endTime {
            query.append(URLQueryItem(name: "endTime", value: Self.isoString(endTime)))
        }
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    static func _parseSummaryForTesting(_ data: Data, now: Date = Date()) throws -> FireworksUsageSummary {
        try self.parseSummary(data: data, now: now)
    }

    private static func parseSummary(data: Data, now: Date) throws -> FireworksUsageSummary {
        let response: FireworksBillingSummaryResponse
        do {
            response = try JSONDecoder().decode(FireworksBillingSummaryResponse.self, from: data)
        } catch {
            throw FireworksUsageError.parseFailed(error.localizedDescription)
        }

        // Rated line items arrive grouped by category/model; the newest-rated currency
        // decides the display currency and only rows in that currency are summed.
        var currency: String?
        var total = 0.0
        for item in response.lineItems ?? [] {
            guard let cost = item.totalCost,
                  let units = cost.units.flatMap(Double.init),
                  let nanos = cost.nanos,
                  let code = cost.currencyCode?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !code.isEmpty
            else {
                continue
            }
            if currency == nil {
                currency = code
            }
            guard code == currency else { continue }
            total += units + Double(nanos) / 1_000_000_000
        }

        return FireworksUsageSummary(
            last30DaysSpend: currency.map { _ in total },
            currencyCode: currency,
            updatedAt: now)
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private struct FireworksBillingSummaryResponse: Decodable {
    let lineItems: [FireworksLineItem]?
    let usageBuckets: [FireworksUsageBucket]?
}

private struct FireworksLineItem: Decodable {
    let category: String?
    let groupingKey: String?
    let groupingValue: String?
    let quantity: Double?
    let series: String?
    let totalCost: FireworksMoney?
    let unitAmount: FireworksMoney?
}

private struct FireworksMoney: Decodable {
    let currencyCode: String?
    let nanos: Int?
    let units: String?
}

private struct FireworksUsageBucket: Decodable {
    let bucketStartTime: String?
    let lineItems: [FireworksLineItem]?
}
