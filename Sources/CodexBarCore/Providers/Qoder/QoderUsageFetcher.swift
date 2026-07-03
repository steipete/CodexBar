import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum QoderWebSite: CaseIterable, Sendable {
    case international
    case china

    var usageURL: URL {
        switch self {
        case .international:
            URL(string: "https://qoder.com/api/v2/me/usages/big_model_credits")!
        case .china:
            URL(string: "https://qoder.com.cn/api/v2/me/usages/big_model_credits")!
        }
    }

    public var dashboardURL: URL {
        switch self {
        case .international:
            URL(string: "https://qoder.com/account/usage")!
        case .china:
            URL(string: "https://qoder.com.cn/account/usage")!
        }
    }

    var webOrigin: String {
        switch self {
        case .international:
            "https://qoder.com"
        case .china:
            "https://qoder.com.cn"
        }
    }

    var cookieDomains: [String] {
        switch self {
        case .international:
            ["qoder.com", "www.qoder.com"]
        case .china:
            ["qoder.com.cn", "www.qoder.com.cn"]
        }
    }
}

public enum QoderUsageFetcher {
    private static let log = CodexBarLog.logger(LogCategories.qoderUsage)
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    public static func fetchUsage(
        cookieHeader: String,
        site: QoderWebSite = .international,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date(),
        timeout: TimeInterval = 15) async throws -> QoderUsageSnapshot
    {
        let data = try await self.send(
            cookieHeader: cookieHeader,
            site: site,
            transport: transport,
            timeout: timeout)
        return try self.parseUsage(data: data, now: now)
    }

    private static func send(
        cookieHeader: String,
        site: QoderWebSite,
        transport: any ProviderHTTPTransport,
        timeout: TimeInterval) async throws -> Data
    {
        var request = URLRequest(url: site.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(site.webOrigin, forHTTPHeaderField: "Origin")
        request.setValue("\(site.webOrigin)/account/usage", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("2.5.35", forHTTPHeaderField: "Bx-V")

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw QoderUsageError.networkError(error.localizedDescription)
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw QoderUsageError.invalidCredentials
        }
        guard (200..<300).contains(response.statusCode) else {
            Self.log.error("Qoder usage API returned \(response.statusCode)")
            throw QoderUsageError.apiError(response.statusCode)
        }
        return response.data
    }

    static func parseUsage(data: Data, now: Date = Date()) throws -> QoderUsageSnapshot {
        let response: QoderUsageResponse
        do {
            response = try JSONDecoder().decode(QoderUsageResponse.self, from: data)
        } catch {
            throw QoderUsageError.parseFailed("invalid JSON: \(error.localizedDescription)")
        }

        guard let summary = response.totalQuota?.quotaSummary else {
            throw QoderUsageError.parseFailed("missing totalQuota.quotaSummary")
        }

        let merged = try Self.mergedQuota(
            base: summary,
            shared: response.sharedQuota?.quotaSummary)

        return QoderUsageSnapshot(
            usedCredits: merged.usedCredits,
            totalCredits: merged.totalCredits,
            remainingCredits: merged.remainingCredits,
            usagePercentage: merged.usagePercentage,
            unit: merged.unit,
            resetsAt: response.nextResetAt,
            updatedAt: now)
    }

    private struct MergedQuota {
        let usedCredits: Double
        let totalCredits: Double
        let remainingCredits: Double
        let usagePercentage: Double
        let unit: String?
    }

    private static func mergedQuota(
        base: QoderQuotaSummary,
        shared: QoderQuotaSummary?) throws -> MergedQuota
    {
        let baseUsed = base.usedValue
        let baseTotal = base.limitValue
        let baseRemaining = try Self.remainingCredits(for: base)

        guard let shared else {
            let percentage = try Self.usagePercentage(
                used: baseUsed,
                total: baseTotal,
                remaining: baseRemaining,
                provided: base.usagePercentage)
            return MergedQuota(
                usedCredits: baseUsed,
                totalCredits: baseTotal,
                remainingCredits: baseRemaining,
                usagePercentage: percentage,
                unit: base.unit)
        }

        let sharedUsed = shared.usedValue
        let sharedTotal = shared.limitValue
        let sharedRemaining = try Self.remainingCredits(for: shared)
        let used = baseUsed + sharedUsed
        let total = baseTotal + sharedTotal
        let remaining = baseRemaining + sharedRemaining
        let percentage = try Self.usagePercentage(
            used: used,
            total: total,
            remaining: remaining,
            provided: nil)
        return MergedQuota(
            usedCredits: used,
            totalCredits: total,
            remainingCredits: remaining,
            usagePercentage: percentage,
            unit: base.unit ?? shared.unit)
    }

    private static func remainingCredits(for summary: QoderQuotaSummary) throws -> Double {
        guard summary.usedValue >= 0,
              summary.limitValue >= 0,
              summary.remainingValue.map({ $0 >= 0 }) ?? true
        else {
            throw QoderUsageError.parseFailed("quota values must be nonnegative")
        }
        return summary.remainingValue ?? max(0, summary.limitValue - summary.usedValue)
    }

    private static func usagePercentage(
        used: Double,
        total: Double,
        remaining: Double,
        provided: Double?) throws -> Double
    {
        guard used >= 0, total >= 0, remaining >= 0 else {
            throw QoderUsageError.parseFailed("quota values must be nonnegative")
        }
        guard total > 0 else {
            guard used == 0, remaining == 0 else {
                throw QoderUsageError.parseFailed("zero total quota must have zero usage and remaining")
            }
            return provided ?? 100
        }
        return provided ?? (used / total) * 100
    }
}

private struct QoderUsageResponse: Decodable {
    let totalQuota: QoderQuotaContainer?
    let sharedQuota: QoderQuotaContainer?
    let nextResetAt: Date?

    private enum CodingKeys: String, CodingKey {
        case totalQuota
        case totalQuotaSnake = "total_quota"
        case sharedQuota
        case sharedQuotaSnake = "shared_quota"
        case nextResetAt
        case nextResetAtSnake = "next_reset_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.totalQuota =
            try container.decodeIfPresent(QoderQuotaContainer.self, forKey: .totalQuota) ??
            container.decodeIfPresent(QoderQuotaContainer.self, forKey: .totalQuotaSnake)
        self.sharedQuota =
            try container.decodeIfPresent(QoderQuotaContainer.self, forKey: .sharedQuota) ??
            container.decodeIfPresent(QoderQuotaContainer.self, forKey: .sharedQuotaSnake)
        self.nextResetAt =
            Self.decodeDate(from: container, forKey: .nextResetAt) ??
            Self.decodeDate(from: container, forKey: .nextResetAtSnake)
    }

    private static func decodeDate(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys) -> Date?
    {
        if let value = try? container.decode(String.self, forKey: key) {
            return self.parseISO8601Date(value)
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            let seconds = value > 10_000_000_000 ? value / 1000 : value
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

private struct QoderQuotaContainer: Decodable {
    let quotaSummary: QoderQuotaSummary?

    private enum CodingKeys: String, CodingKey {
        case quotaSummary
        case quotaSummarySnake = "quota_summary"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.quotaSummary =
            try container.decodeIfPresent(QoderQuotaSummary.self, forKey: .quotaSummary) ??
            container.decodeIfPresent(QoderQuotaSummary.self, forKey: .quotaSummarySnake)
    }
}

private struct QoderQuotaSummary: Decodable {
    let usedValue: Double
    let limitValue: Double
    let remainingValue: Double?
    let usagePercentage: Double?
    let unit: String?

    private enum CodingKeys: String, CodingKey {
        case usedValue
        case usedValueSnake = "used_value"
        case limitValue
        case limitValueSnake = "limit_value"
        case remainingValue
        case remainingValueSnake = "remaining_value"
        case usagePercentage
        case usagePercentageSnake = "usage_percentage"
        case unit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usedValue =
            try container.decodeIfPresent(Double.self, forKey: .usedValue) ??
            container.decode(Double.self, forKey: .usedValueSnake)
        self.limitValue =
            try container.decodeIfPresent(Double.self, forKey: .limitValue) ??
            container.decode(Double.self, forKey: .limitValueSnake)
        self.remainingValue =
            try container.decodeIfPresent(Double.self, forKey: .remainingValue) ??
            container.decodeIfPresent(Double.self, forKey: .remainingValueSnake)
        self.usagePercentage =
            try container.decodeIfPresent(Double.self, forKey: .usagePercentage) ??
            container.decodeIfPresent(Double.self, forKey: .usagePercentageSnake)
        self.unit = try container.decodeIfPresent(String.self, forKey: .unit)
    }
}
