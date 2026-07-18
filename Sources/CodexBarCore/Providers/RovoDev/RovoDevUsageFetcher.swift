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

    public init(
        dailyTotal: Int?,
        dailyRemaining: Int?,
        dailyUsed: Int?,
        monthlyTotal: Int?,
        monthlyRemaining: Int?,
        monthlyUsed: Int?)
    {
        self.dailyTotal = dailyTotal
        self.dailyRemaining = dailyRemaining
        self.dailyUsed = dailyUsed
        self.monthlyTotal = monthlyTotal
        self.monthlyRemaining = monthlyRemaining
        self.monthlyUsed = monthlyUsed
    }
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
        self.preferredCredits.used
    }

    /// Monthly total credits (prefers monthly, falls back to daily).
    public var creditsTotal: Int? {
        self.preferredCredits.total
    }

    public var usedPercent: Double {
        guard let used = self.creditsUsed,
              let total = self.creditsTotal,
              total > 0
        else { return 0 }
        return max(0, min(100, Double(used) / Double(total) * 100))
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let primary: RateWindow? = if let total = self.creditsTotal, total > 0, self.creditsUsed != nil {
            RateWindow(
                usedPercent: self.usedPercent,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: self.creditSummary)
        } else {
            nil
        }

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

    private var preferredCredits: (used: Int?, total: Int?) {
        if let used = Self.usedCredits(
            explicit: self.balance.monthlyUsed,
            total: self.balance.monthlyTotal,
            remaining: self.balance.monthlyRemaining)
        {
            return (used, self.balance.monthlyTotal)
        }
        if let used = Self.usedCredits(
            explicit: self.balance.dailyUsed,
            total: self.balance.dailyTotal,
            remaining: self.balance.dailyRemaining)
        {
            return (used, self.balance.dailyTotal)
        }
        return (nil, self.balance.monthlyTotal ?? self.balance.dailyTotal)
    }

    private static func usedCredits(explicit: Int?, total: Int?, remaining: Int?) -> Int? {
        if let total, let remaining {
            return total - remaining
        }
        return explicit
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
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> RovoDevUsageSnapshot
    {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !trimmedToken.isEmpty else {
            throw RovoDevUsageError.missingCredentials
        }

        try RovoDevSettingsReader.validateEndpointOverrides(environment: environment)
        let baseURL = RovoDevSettingsReader.apiURL(environment: environment)
        let cloudId = RovoDevSettingsReader.cloudId(environment: environment)

        var url = Self.creditsCheckURL(baseURL: baseURL)
        if let cloudId, !cloudId.isEmpty {
            if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var queryItems = components.queryItems ?? []
                queryItems.append(URLQueryItem(name: "cloudId", value: cloudId))
                components.queryItems = queryItems
                if let newUrl = components.url {
                    url = newUrl
                }
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        if let cloudId, !cloudId.isEmpty {
            request.setValue(cloudId, forHTTPHeaderField: "X-Atlassian-Cloud-Id")
        }

        // Basic auth: base64("email:apiToken")
        let credentials = "\(trimmedEmail):\(trimmedToken)"
        if let encoded = credentials.data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }

        let response = try await transport.response(for: request)
        switch response.statusCode {
        case 200, 403:
            let decoded = try Self.decodeResponse(data: response.data)
            guard decoded.isRecognizedPayload else {
                Self.log.error("Rovo Dev API returned an unrecognized HTTP \(response.statusCode) response")
                if response.statusCode == 200 {
                    throw RovoDevUsageError.parseFailed("Unrecognized response payload")
                }
                throw RovoDevUsageError.apiError(response.statusCode)
            }
            return Self.makeSnapshot(from: decoded, accountEmail: trimmedEmail, updatedAt: Date())
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
        let decoded = try self.decodeResponse(data: data)
        return self.makeSnapshot(from: decoded, accountEmail: accountEmail, updatedAt: updatedAt)
    }

    private static func decodeResponse(data: Data) throws -> CreditsCheckResponse {
        do {
            let response = try JSONDecoder().decode(CreditsCheckResponse.self, from: data)
            guard response.balance?.isValid ?? true else {
                throw RovoDevUsageError.parseFailed("Invalid credit balance")
            }
            guard response.retryAfterSeconds.map({ $0 >= 0 }) ?? true else {
                throw RovoDevUsageError.parseFailed("Invalid retry interval")
            }
            guard response.modelUsages?.values.allSatisfy({ $0 >= 0 }) ?? true else {
                throw RovoDevUsageError.parseFailed("Invalid model usage")
            }
            return response
        } catch let error as RovoDevUsageError {
            throw error
        } catch {
            throw RovoDevUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func makeSnapshot(
        from decoded: CreditsCheckResponse,
        accountEmail: String?,
        updatedAt: Date) -> RovoDevUsageSnapshot
    {
        RovoDevUsageSnapshot(
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

extension RovoDevBalance {
    fileprivate var isValid: Bool {
        Self.isValidWindow(total: self.monthlyTotal, remaining: self.monthlyRemaining, used: self.monthlyUsed) &&
            Self.isValidWindow(total: self.dailyTotal, remaining: self.dailyRemaining, used: self.dailyUsed)
    }

    fileprivate static func isValidWindow(total: Int?, remaining: Int?, used: Int?) -> Bool {
        guard [total, remaining, used].compactMap(\.self).allSatisfy({ $0 >= 0 }) else { return false }
        guard let total else { return true }
        return remaining.map { $0 <= total } ?? true && used.map { $0 <= total } ?? true
    }
}

// MARK: - Private response models

private struct CreditsCheckResponse: Decodable {
    private static let recognizedStatuses = ["OK", "RATE_LIMITED", "USER_BLOCKED", "UNKNOWN"]

    let status: String?
    let balance: RovoDevBalance?
    let message: String?
    let retryAfterSeconds: Int?
    /// Per-model token usage map, e.g. {"Claude Haiku 4.5": 91295, "claude-sonnet-4-6": 18862727}
    let modelUsages: [String: Int]?

    var isRecognizedPayload: Bool {
        self.balance != nil
            || self.status.map { Self.recognizedStatuses.contains($0.uppercased()) } == true
    }
}
