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
    public let usage: Int?
    public let currentValue: Int?
    public let remaining: Int?
    public let percentage: Double
    public let usageDetails: [ZaiUsageDetail]
    public let nextResetTime: Date?

    public init(
        type: ZaiLimitType,
        unit: ZaiLimitUnit,
        number: Int,
        usage: Int?,
        currentValue: Int?,
        remaining: Int?,
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
        guard let limit = self.usage, limit > 0 else { return nil }

        // z.ai sometimes omits quota fields; don't invent zeros (can yield 100% used incorrectly).
        var usedRaw: Int?
        if let remaining = self.remaining {
            let usedFromRemaining = limit - remaining
            if let currentValue = self.currentValue {
                usedRaw = max(usedFromRemaining, currentValue)
            } else {
                usedRaw = usedFromRemaining
            }
        } else if let currentValue = self.currentValue {
            usedRaw = currentValue
        }
        guard let usedRaw else { return nil }

        let used = max(0, min(limit, usedRaw))
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
    public let planName: String?
    public let updatedAt: Date

    public init(tokenLimit: ZaiLimitEntry?, timeLimit: ZaiLimitEntry?, planName: String?, updatedAt: Date) {
        self.tokenLimit = tokenLimit
        self.timeLimit = timeLimit
        self.planName = planName
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

        let planName = self.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginMethod = (planName?.isEmpty ?? true) ? nil : planName
        let identity = ProviderIdentitySnapshot(
            providerID: .zai,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginMethod)
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: nil,
            zaiUsage: self,
            updatedAt: self.updatedAt,
            identity: identity)
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
private struct ZaiQuotaLimitResponse: Decodable {
    let code: Int
    let msg: String
    let data: ZaiQuotaLimitData?
    let success: Bool

    var isSuccess: Bool {
        self.success && self.code == 200
    }
}

private struct ZaiQuotaLimitData: Decodable {
    let limits: [ZaiLimitRaw]
    let planName: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.limits = try container.decodeIfPresent([ZaiLimitRaw].self, forKey: .limits) ?? []
        let rawPlan = try [
            container.decodeIfPresent(String.self, forKey: .planName),
            container.decodeIfPresent(String.self, forKey: .plan),
            container.decodeIfPresent(String.self, forKey: .planType),
            container.decodeIfPresent(String.self, forKey: .packageName),
        ].compactMap(\.self).first
        let trimmed = rawPlan?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.planName = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case limits
        case planName
        case plan
        case planType = "plan_type"
        case packageName
    }
}

private struct ZaiLimitRaw: Codable {
    let type: String
    let unit: Int
    let number: Int
    let usage: Int?
    let currentValue: Int?
    let remaining: Int?
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
    private static let log = CodexBarLog.logger(LogCategories.zaiUsage)

    /// Path for z.ai quota API
    private static let quotaAPIPath = "api/monitor/usage/quota/limit"

    /// Resolves the quota URL using (in order):
    /// 1) `Z_AI_QUOTA_URL` environment override (full URL).
    /// 2) `Z_AI_API_HOST` environment override (host/base URL).
    /// 3) Region selection (global default).
    public static func resolveQuotaURL(
        region: ZaiAPIRegion,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = ZaiSettingsReader.quotaURL(environment: environment) {
            return override
        }
        if let host = ZaiSettingsReader.apiHost(environment: environment),
           let hostURL = self.quotaURL(baseURLString: host)
        {
            return hostURL
        }
        return region.quotaLimitURL
    }

    /// Fetches usage stats from z.ai using the provided API key
    public static func fetchUsage(
        apiKey: String,
        region: ZaiAPIRegion = .global,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> ZaiUsageSnapshot
    {
        guard !apiKey.isEmpty else {
            throw ZaiUsageError.invalidCredentials
        }

        let quotaURL = self.resolveQuotaURL(region: region, environment: environment)

        var request = URLRequest(url: quotaURL)
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

        // Some upstream issues (wrong endpoint/region/proxy) can yield HTTP 200 with an empty body.
        // JSONDecoder will otherwise throw an opaque Cocoa error ("data is missing").
        guard !data.isEmpty else {
            Self.log.error("z.ai API returned empty body (HTTP 200) for \(Self.safeURLForLogging(quotaURL))")
            throw ZaiUsageError.parseFailed(
                "Empty response body (HTTP 200). Check z.ai API region (Global vs BigModel CN) and your API token.")
        }

        // Log raw response for debugging
        if let jsonString = String(data: data, encoding: .utf8) {
            Self.log.debug("z.ai API response: \(jsonString)")
        }

        do {
            return try Self.parseUsageSnapshot(from: data)
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

    private static func safeURLForLogging(_ url: URL) -> String {
        let host = url.host ?? "<unknown-host>"
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        return "\(host)\(port)\(path)"
    }

    static func parseUsageSnapshot(from data: Data) throws -> ZaiUsageSnapshot {
        guard !data.isEmpty else {
            throw ZaiUsageError.parseFailed("Empty response body")
        }

        let decoder = JSONDecoder()
        let apiResponse = try decoder.decode(ZaiQuotaLimitResponse.self, from: data)

        guard apiResponse.isSuccess else {
            throw ZaiUsageError.apiError(apiResponse.msg)
        }

        guard let responseData = apiResponse.data else {
            throw ZaiUsageError.parseFailed("Missing data")
        }

        var tokenLimit: ZaiLimitEntry?
        var timeLimit: ZaiLimitEntry?

        for limit in responseData.limits {
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
            planName: responseData.planName,
            updatedAt: Date())
    }

    private static func quotaURL(baseURLString: String) -> URL? {
        guard let cleaned = ZaiSettingsReader.cleaned(baseURLString) else { return nil }

        if let url = URL(string: cleaned), url.scheme != nil {
            if url.path.isEmpty || url.path == "/" {
                return url.appendingPathComponent(Self.quotaAPIPath)
            }
            return url
        }
        guard let base = URL(string: "https://\(cleaned)") else { return nil }
        if base.path.isEmpty || base.path == "/" {
            return base.appendingPathComponent(Self.quotaAPIPath)
        }
        return base
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
