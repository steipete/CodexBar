import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ClinePassUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case unauthorized
    case apiError(Int)
    case networkError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing ClinePass API key. Set CLINE_API_KEY or CLINEPASS_API_KEY."
        case .unauthorized:
            "ClinePass API key was rejected."
        case let .apiError(statusCode):
            "ClinePass API error: HTTP \(statusCode)"
        case let .networkError(message):
            "ClinePass network error: \(message)"
        case let .parseFailed(message):
            "Failed to parse ClinePass response: \(message)"
        }
    }
}

public struct ClinePassUsageSnapshot: Sendable, Equatable {
    public let primary: RateWindow?
    public let secondary: RateWindow?
    public let tertiary: RateWindow?
    public let updatedAt: Date

    public init(
        primary: RateWindow?,
        secondary: RateWindow?,
        tertiary: RateWindow?,
        updatedAt: Date)
    {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: self.primary,
            secondary: self.secondary,
            tertiary: self.tertiary,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .clinepass,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "API key"))
    }
}

private enum ClinePassLimitType: Decodable, Hashable, Sendable {
    case fiveHour
    case weekly
    case monthly
    case unknown(String)

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = switch rawValue {
        case "five_hour": .fiveHour
        case "weekly": .weekly
        case "monthly": .monthly
        default: .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .fiveHour: "five_hour"
        case .weekly: "weekly"
        case .monthly: "monthly"
        case let .unknown(value): value
        }
    }

    var windowMinutes: Int? {
        switch self {
        case .fiveHour:
            5 * 60
        case .weekly:
            7 * 24 * 60
        case .monthly:
            30 * 24 * 60
        case .unknown:
            nil
        }
    }
}

private struct ClinePassLimit: Decodable, Sendable {
    let type: ClinePassLimitType
    let percentUsed: Double
    let resetsAt: String?
}

private struct ClinePassLimitsData: Decodable, Sendable {
    let limits: [ClinePassLimit]
}

private struct ClinePassLimitsResponse: Decodable, Sendable {
    let data: ClinePassLimitsData
    let success: Bool
}

public struct ClinePassUsageFetcher: Sendable {
    private static let usageURL = URL(string: "https://api.cline.bot/api/v1/users/me/plan/usage-limits")!
    private static let timeoutSeconds: TimeInterval = 15

    public static func fetchUsage(apiKey: String) async throws -> ClinePassUsageSnapshot {
        try await self._fetchUsage(apiKey: apiKey, transport: ProviderHTTPClient.shared)
    }

    static func _fetchUsage(
        apiKey: String,
        transport: any ProviderHTTPTransport,
        now: Date = Date()) async throws -> ClinePassUsageSnapshot
    {
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else {
            throw ClinePassUsageError.missingCredentials
        }

        var request = URLRequest(url: self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(cleanedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = self.timeoutSeconds

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch {
            throw ClinePassUsageError.networkError(error.localizedDescription)
        }

        switch response.statusCode {
        case 200:
            return try self.parseSnapshot(data: response.data, updatedAt: now)
        case 401, 403:
            throw ClinePassUsageError.unauthorized
        default:
            throw ClinePassUsageError.apiError(response.statusCode)
        }
    }

    static func _parseSnapshotForTesting(
        _ data: Data,
        updatedAt: Date = Date()) throws -> ClinePassUsageSnapshot
    {
        try self.parseSnapshot(data: data, updatedAt: updatedAt)
    }

    private static func parseSnapshot(data: Data, updatedAt: Date) throws -> ClinePassUsageSnapshot {
        let response: ClinePassLimitsResponse
        do {
            response = try JSONDecoder().decode(ClinePassLimitsResponse.self, from: data)
        } catch {
            throw ClinePassUsageError.parseFailed(error.localizedDescription)
        }

        guard response.success else {
            throw ClinePassUsageError.parseFailed("Response success was false.")
        }

        var windows: [ClinePassLimitType: RateWindow] = [:]
        for limit in response.data.limits {
            guard limit.type.windowMinutes != nil else {
                continue
            }
            windows[limit.type] = try self.rateWindow(for: limit)
        }

        return ClinePassUsageSnapshot(
            primary: windows[.fiveHour],
            secondary: windows[.weekly],
            tertiary: windows[.monthly],
            updatedAt: updatedAt)
    }

    private static func rateWindow(for limit: ClinePassLimit) throws -> RateWindow {
        guard let windowMinutes = limit.type.windowMinutes else {
            throw ClinePassUsageError.parseFailed("Unknown ClinePass limit type \(limit.type.rawValue).")
        }

        let resetsAt: Date?
        if let raw = limit.resetsAt {
            guard let parsed = self.parseISO8601Date(raw) else {
                throw ClinePassUsageError.parseFailed("Invalid resetsAt timestamp for \(limit.type.rawValue).")
            }
            resetsAt = parsed
        } else {
            resetsAt = nil
        }

        return RateWindow(
            usedPercent: min(100, max(0, limit.percentUsed)),
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: nil)
    }

    private static func parseISO8601Date(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
