import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Snapshot models

/// Raw balance data from the credits/check endpoint.
public struct RovoDevBalance: Decodable, Sendable, Equatable {
    public let dailyTotal: Int?
    public let dailyRemaining: Int?
    public let dailyUsed: Int?
    public let monthlyTotal: Int?
    public let monthlyRemaining: Int?
    public let monthlyUsed: Int?
}

/// Parsed snapshot from the Rovo Dev credits/check response.
public struct RovoDevUsageSnapshot: Sendable, Equatable {
    public let status: String
    public let balance: RovoDevBalance
    public let message: String?
    public let retryAfterSeconds: Int?
    /// Per-model token usage, e.g. {"Claude Haiku 4.5": 91295}
    public let modelUsages: [String: Int]?
    public let accountEmail: String?
    public let updatedAt: Date

    public init(
        status: String,
        balance: RovoDevBalance,
        message: String?,
        retryAfterSeconds: Int? = nil,
        modelUsages: [String: Int]? = nil,
        accountEmail: String? = nil,
        updatedAt: Date)
    {
        self.status = status
        self.balance = balance
        self.message = message
        self.retryAfterSeconds = retryAfterSeconds
        self.modelUsages = modelUsages
        self.accountEmail = accountEmail
        self.updatedAt = updatedAt
    }

    /// Monthly used credits (prefers monthly, falls back to daily).
    public var creditsUsed: Int? {
        self.balance.monthlyUsed ?? self.balance.dailyUsed
    }

    /// Monthly total credits (prefers monthly, falls back to daily).
    public var creditsTotal: Int? {
        self.balance.monthlyTotal ?? self.balance.dailyTotal
    }

    public var usedPercent: Double {
        guard let used = self.creditsUsed,
              let total = self.creditsTotal,
              total > 0
        else { return 0 }
        return max(0, min(100, Double(used) / Double(total) * 100))
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let resetDescription = self.creditSummary
        let primary = RateWindow(
            usedPercent: self.usedPercent,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: resetDescription)

        let loginMethod: String? = self.displayStatus
        let identity = ProviderIdentitySnapshot(
            providerID: .rovodev,
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: loginMethod)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private var creditSummary: String? {
        guard let used = self.creditsUsed else { return nil }
        if let total = self.creditsTotal {
            return "\(used) / \(total) credits"
        }
        return "\(used) credits used"
    }

    private var displayStatus: String? {
        switch self.status.uppercased() {
        case "OK": "Active"
        case "RATE_LIMITED": "Rate Limited"
        case "USER_BLOCKED": "Blocked"
        case "UNKNOWN": nil
        default: self.status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// MARK: - Errors

public enum RovoDevUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case networkError(String)
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Rovo Dev credentials. Set ROVODEV_API_TOKEN and ROVODEV_EMAIL in your environment, " +
                "or provide them in ~/.codexbar/config.json."
        case let .networkError(msg):
            "Rovo Dev network error: \(msg)"
        case let .apiError(code):
            "Rovo Dev API error: HTTP \(code)"
        case let .parseFailed(msg):
            "Failed to parse Rovo Dev response: \(msg)"
        }
    }
}

// MARK: - Fetcher

public struct RovoDevUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.rovoDevUsage)
    private static let timeoutSeconds: TimeInterval = 15

    /// Fetch usage snapshot using email + API token (Basic auth).
    public static func fetchUsage(
        email: String,
        apiToken: String,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> RovoDevUsageSnapshot
    {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !trimmedToken.isEmpty else {
            throw RovoDevUsageError.missingCredentials
        }

        try RovoDevSettingsReader.validateEndpointOverrides(environment: environment)
        let url = Self.creditsCheckURL(baseURL: RovoDevSettingsReader.apiURL(environment: environment))
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        // Basic auth: base64("email:apiToken")
        let credentials = "\(trimmedEmail):\(trimmedToken)"
        if let encoded = credentials.data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }

        let response = try await ProviderHTTPClient.shared.response(for: request)
        switch response.statusCode {
        case 200, 403:
            // 403 can still contain valid usage data (e.g. USER_BLOCKED status)
            return try Self.parseSnapshot(data: response.data, accountEmail: trimmedEmail, updatedAt: Date())
        case 401:
            throw RovoDevUsageError.missingCredentials
        default:
            Self.log.error("Rovo Dev API returned \(response.statusCode)")
            throw RovoDevUsageError.apiError(response.statusCode)
        }
    }

    static func _parseSnapshotForTesting(_ data: Data, updatedAt: Date) throws -> RovoDevUsageSnapshot {
        try self.parseSnapshot(data: data, updatedAt: updatedAt)
    }

    static func _creditsCheckURLForTesting(baseURL: URL) -> URL {
        self.creditsCheckURL(baseURL: baseURL)
    }

    private static func parseSnapshot(
        data: Data,
        accountEmail: String? = nil,
        updatedAt: Date) throws -> RovoDevUsageSnapshot
    {
        let decoded: CreditsCheckResponse
        do {
            decoded = try JSONDecoder().decode(CreditsCheckResponse.self, from: data)
        } catch {
            throw RovoDevUsageError.parseFailed(error.localizedDescription)
        }
        return RovoDevUsageSnapshot(
            status: decoded.status ?? "UNKNOWN",
            balance: decoded.balance ?? RovoDevBalance(
                dailyTotal: nil,
                dailyRemaining: nil,
                dailyUsed: nil,
                monthlyTotal: nil,
                monthlyRemaining: nil,
                monthlyUsed: nil),
            message: decoded.message,
            retryAfterSeconds: decoded.retryAfterSeconds,
            modelUsages: decoded.modelUsages,
            accountEmail: accountEmail,
            updatedAt: updatedAt)
    }

    private static func creditsCheckURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("rovodev/v3/credits/check")
    }
}

// MARK: - Private response models

private struct CreditsCheckResponse: Decodable {
    let status: String?
    let balance: RovoDevBalance?
    let message: String?
    let retryAfterSeconds: Int?
    /// Per-model token usage map, e.g. {"Claude Haiku 4.5": 91295, "claude-sonnet-4-6": 18862727}
    let modelUsages: [String: Int]?
}
