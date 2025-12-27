import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Z.ai usage limit types from the API
public enum ZaiLimitType: String, Sendable {
    case timeLimit = "TIME_LIMIT"
    case tokensLimit = "TOKENS_LIMIT"
}

/// Z.ai usage limit unit types
public enum ZaiLimitUnit: Int, Sendable {
    case unknown = 0
    case days = 1
    case hours = 3
    case minutes = 5
}

/// A single limit entry from the z.ai API
public struct ZaiLimitEntry: Sendable {
    public let type: ZaiLimitType
    public let unit: ZaiLimitUnit
    public let number: Int
    public let usage: Int
    public let currentValue: Int
    public let remaining: Int
    public let percentage: Double
    public let usageDetails: [ZaiUsageDetail]
    public let nextResetTime: Date?

    public init(
        type: ZaiLimitType,
        unit: ZaiLimitUnit,
        number: Int,
        usage: Int,
        currentValue: Int,
        remaining: Int,
        percentage: Double,
        usageDetails: [ZaiUsageDetail],
        nextResetTime: Date?)
    {
        self.type = type
        self.unit = unit
        self.number = number
        self.usage = usage
        self.currentValue = currentValue
        self.remaining = remaining
        self.percentage = percentage
        self.usageDetails = usageDetails
        self.nextResetTime = nextResetTime
    }
}

extension ZaiLimitEntry {
    public var usedPercent: Double {
        if let computed = self.computedUsedPercent {
            return computed
        }
        return self.percentage
    }

    public var windowMinutes: Int? {
        guard self.number > 0 else { return nil }
        switch self.unit {
        case .minutes:
            return self.number
        case .hours:
            return self.number * 60
        case .days:
            return self.number * 24 * 60
        case .unknown:
            return nil
        }
    }

    public var windowDescription: String? {
        guard self.number > 0 else { return nil }
        let unitLabel: String? = switch self.unit {
        case .minutes: "minute"
        case .hours: "hour"
        case .days: "day"
        case .unknown: nil
        }
        guard let unitLabel else { return nil }
        let suffix = self.number == 1 ? unitLabel : "\(unitLabel)s"
        return "\(self.number) \(suffix)"
    }

    public var windowLabel: String? {
        guard let description = self.windowDescription else { return nil }
        return "\(description) window"
    }

    private var computedUsedPercent: Double? {
        guard self.usage > 0 else { return nil }
        let limit = max(0, self.usage)
        guard limit > 0 else { return nil }

        let usedFromRemaining = limit - self.remaining
        let used = max(0, min(limit, max(usedFromRemaining, self.currentValue)))
        let percent = (Double(used) / Double(limit)) * 100
        return min(100, max(0, percent))
    }
}

/// Usage detail for MCP tools
public struct ZaiUsageDetail: Sendable, Codable {
    public let modelCode: String
    public let usage: Int

    public init(modelCode: String, usage: Int) {
        self.modelCode = modelCode
        self.usage = usage
    }
}

/// Complete z.ai usage response
public struct ZaiUsageSnapshot: Sendable {
    public let tokenLimit: ZaiLimitEntry?
    public let timeLimit: ZaiLimitEntry?
    public let updatedAt: Date

    public init(tokenLimit: ZaiLimitEntry?, timeLimit: ZaiLimitEntry?, updatedAt: Date) {
        self.tokenLimit = tokenLimit
        self.timeLimit = timeLimit
        self.updatedAt = updatedAt
    }

    /// Returns true if this snapshot contains valid z.ai data
    public var isValid: Bool {
        self.tokenLimit != nil || self.timeLimit != nil
    }
}

extension ZaiUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let primaryLimit = self.tokenLimit ?? self.timeLimit
        let secondaryLimit = (self.tokenLimit != nil && self.timeLimit != nil) ? self.timeLimit : nil

        let primary = primaryLimit.map { Self.rateWindow(for: $0) } ?? RateWindow(
            usedPercent: 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: nil)
        let secondary = secondaryLimit.map { Self.rateWindow(for: $0) }

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: nil,
            zaiUsage: self,
            updatedAt: self.updatedAt,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "z.ai")
    }

    private static func rateWindow(for limit: ZaiLimitEntry) -> RateWindow {
        RateWindow(
            usedPercent: limit.usedPercent,
            windowMinutes: limit.type == .tokensLimit ? limit.windowMinutes : nil,
            resetsAt: limit.nextResetTime,
            resetDescription: self.resetDescription(for: limit))
    }

    private static func resetDescription(for limit: ZaiLimitEntry) -> String? {
        if let label = limit.windowLabel {
            return label
        }
        if limit.type == .timeLimit {
            return "Monthly"
        }
        return nil
    }
}

/// Z.ai quota limit API response
private struct ZaiQuotaLimitResponse: Codable {
    let code: Int
    let msg: String
    let data: ZaiQuotaLimitData
    let success: Bool

    var isSuccess: Bool { self.success && self.code == 200 }
}

private struct ZaiQuotaLimitData: Codable {
    let limits: [ZaiLimitRaw]
}

private struct ZaiLimitRaw: Codable {
    let type: String
    let unit: Int
    let number: Int
    let usage: Int
    let currentValue: Int
    let remaining: Int
    let percentage: Int
    let usageDetails: [ZaiUsageDetail]?
    let nextResetTime: Int?

    func toLimitEntry() -> ZaiLimitEntry? {
        guard let limitType = ZaiLimitType(rawValue: type) else { return nil }
        let limitUnit = ZaiLimitUnit(rawValue: unit) ?? .unknown
        let nextReset = self.nextResetTime.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        return ZaiLimitEntry(
            type: limitType,
            unit: limitUnit,
            number: self.number,
            usage: self.usage,
            currentValue: self.currentValue,
            remaining: self.remaining,
            percentage: Double(self.percentage),
            usageDetails: self.usageDetails ?? [],
            nextResetTime: nextReset)
    }
}

/// Fetches usage stats from the z.ai API
public struct ZaiUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger("zai-usage")

    /// Base URL for z.ai quota API
    private static let quotaAPIURL = "https://api.z.ai/api/monitor/usage/quota/limit"

    /// Fetches usage stats from z.ai using the provided API key
    public static func fetchUsage(apiKey: String) async throws -> ZaiUsageSnapshot {
        guard !apiKey.isEmpty else {
            throw ZaiUsageError.invalidCredentials
        }

        var request = URLRequest(url: URL(string: quotaAPIURL)!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ZaiUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            Self.log.error("z.ai API returned \(httpResponse.statusCode): \(errorMessage)")
            throw ZaiUsageError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        // Log raw response for debugging
        if let jsonString = String(data: data, encoding: .utf8) {
            Self.log.debug("z.ai API response: \(jsonString)")
        }

        let decoder = JSONDecoder()
        do {
            let apiResponse = try decoder.decode(ZaiQuotaLimitResponse.self, from: data)

            guard apiResponse.isSuccess else {
                throw ZaiUsageError.apiError(apiResponse.msg)
            }

            var tokenLimit: ZaiLimitEntry?
            var timeLimit: ZaiLimitEntry?

            for limit in apiResponse.data.limits {
                if let entry = limit.toLimitEntry() {
                    switch entry.type {
                    case .tokensLimit:
                        tokenLimit = entry
                    case .timeLimit:
                        timeLimit = entry
                    }
                }
            }

            return ZaiUsageSnapshot(
                tokenLimit: tokenLimit,
                timeLimit: timeLimit,
                updatedAt: Date())
        } catch let error as DecodingError {
            Self.log.error("z.ai JSON decoding error: \(error.localizedDescription)")
            throw ZaiUsageError.parseFailed(error.localizedDescription)
        } catch let error as ZaiUsageError {
            throw error
        } catch {
            Self.log.error("z.ai parsing error: \(error.localizedDescription)")
            throw ZaiUsageError.parseFailed(error.localizedDescription)
        }
    }
}

/// Errors that can occur during z.ai usage fetching
public enum ZaiUsageError: LocalizedError, Sendable {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Invalid z.ai API credentials"
        case let .networkError(message):
            "z.ai network error: \(message)"
        case let .apiError(message):
            "z.ai API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse z.ai response: \(message)"
        }
    }
}
