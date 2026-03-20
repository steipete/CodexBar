import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Regular API Key Response

/// Grok/xAI API key info response from GET /v1/api-key
public struct GrokAPIKeyResponse: Decodable, Sendable {
    public let apiKeyId: String?
    public let name: String?
    public let redactedApiKey: String?
    public let teamBlocked: Bool?
    public let apiKeyBlocked: Bool?
    public let apiKeyDisabled: Bool?

    private enum CodingKeys: String, CodingKey {
        case apiKeyId = "api_key_id"
        case name
        case redactedApiKey = "redacted_api_key"
        case teamBlocked = "team_blocked"
        case apiKeyBlocked = "api_key_blocked"
        case apiKeyDisabled = "api_key_disabled"
    }

    /// Whether this API key is active and usable
    public var isActive: Bool {
        !(self.teamBlocked ?? false) && !(self.apiKeyBlocked ?? false) && !(self.apiKeyDisabled ?? false)
    }
}

// MARK: - Management API Billing Responses

/// Helper for xAI's `{"val": "12345"}` cent-string wrapper
struct GrokCentValue: Decodable, Sendable {
    let val: String

    /// Converts from USD cents string to dollars
    var dollars: Double {
        guard let cents = Double(self.val) else { return 0 }
        return cents / 100.0
    }
}

/// Spending limits from GET /v1/billing/teams/{team_id}/postpaid/spending-limits
public struct GrokSpendingLimitsResponse: Decodable, Sendable {
    public let spendingLimits: SpendingLimits

    public struct SpendingLimits: Decodable, Sendable {
        let effectiveHardSl: GrokCentValue?
        let hardSlAuto: GrokCentValue?
        let softSl: GrokCentValue?
        let effectiveSl: GrokCentValue?
    }

    /// The effective spending limit in dollars
    var effectiveLimitDollars: Double {
        self.spendingLimits.effectiveSl?.dollars
            ?? self.spendingLimits.effectiveHardSl?.dollars
            ?? self.spendingLimits.softSl?.dollars
            ?? 0
    }
}

/// Invoice preview from GET /v1/billing/teams/{team_id}/postpaid/invoice/preview
public struct GrokInvoicePreviewResponse: Decodable, Sendable {
    public let coreInvoice: CoreInvoice
    public let effectiveSpendingLimit: String?
    public let defaultCredits: String?
    public let billingCycle: BillingCycle?

    public struct CoreInvoice: Decodable, Sendable {
        let amountBeforeVat: String?
        let amountAfterVat: String?
        let prepaidCreditsUsed: GrokCentValue?
    }

    public struct BillingCycle: Decodable, Sendable {
        let year: Int?
        let month: Int?
    }

    /// Current usage in dollars (from cents string)
    var usageDollars: Double {
        guard let cents = self.coreInvoice.amountBeforeVat, let val = Double(cents) else { return 0 }
        return val / 100.0
    }

    /// Spending limit in dollars (from top-level cents string)
    var limitDollars: Double {
        guard let cents = self.effectiveSpendingLimit, let val = Double(cents) else { return 0 }
        return val / 100.0
    }
}

// MARK: - Snapshots

/// Complete Grok usage snapshot from Management API billing data
public struct GrokBillingSnapshot: Sendable {
    public let usageCap: Double
    public let totalUsage: Double
    public let remaining: Double
    public let usedPercent: Double
    public let updatedAt: Date

    public init(usageCap: Double, totalUsage: Double, remaining: Double, usedPercent: Double, updatedAt: Date) {
        self.usageCap = usageCap
        self.totalUsage = totalUsage
        self.remaining = remaining
        self.usedPercent = usedPercent
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let primary = RateWindow(
            usedPercent: self.usedPercent,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: nil)

        let balanceStr = String(format: "$%.2f", self.remaining)
        let capStr = String(format: "$%.2f", self.usageCap)
        let identity = ProviderIdentitySnapshot(
            providerID: .grok,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Balance: \(balanceStr) / \(capStr)")

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

/// Grok key-only snapshot (fallback when no Management key)
public struct GrokKeySnapshot: Sendable {
    public let keyName: String?
    public let redactedKey: String?
    public let isActive: Bool
    public let updatedAt: Date

    public init(keyName: String?, redactedKey: String?, isActive: Bool, updatedAt: Date) {
        self.keyName = keyName
        self.redactedKey = redactedKey
        self.isActive = isActive
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let statusText = self.isActive ? "Active" : "Blocked"
        let loginText: String = if let keyName, !keyName.isEmpty {
            "Key: \(keyName) (\(statusText))"
        } else if let redactedKey, !redactedKey.isEmpty {
            "Key: \(redactedKey) (\(statusText))"
        } else {
            "Key: \(statusText)"
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .grok,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginText)

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

// MARK: - Errors

/// Errors that can occur during Grok usage fetching
public enum GrokUsageError: LocalizedError, Sendable {
    case missingAPIKey
    case missingManagementKey
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Missing xAI API key."
        case .missingManagementKey:
            "Missing xAI Management API key."
        case let .networkError(message):
            "xAI network error: \(message)"
        case let .apiError(message):
            "xAI API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse xAI response: \(message)"
        }
    }
}

// MARK: - Fetcher

/// Fetches usage/billing data from the xAI APIs
public struct GrokUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.grokUsage)
    private static let requestTimeoutSeconds: TimeInterval = 15

    // MARK: Management API (billing data)

    /// Fetches billing data from the xAI Management API
    public static func fetchBilling(
        managementKey: String,
        teamID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> GrokBillingSnapshot
    {
        guard !managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GrokUsageError.missingManagementKey
        }

        let baseURL = GrokSettingsReader.managementAPIURL(environment: environment)

        // Fetch invoice preview (contains both usage amount and spending limit)
        let invoiceURL = baseURL
            .appendingPathComponent("billing/teams/\(teamID)/postpaid/invoice/preview")
        let invoiceResponse: GrokInvoicePreviewResponse = try await Self.fetchJSON(
            url: invoiceURL, bearerToken: managementKey)

        // Use spending limit from invoice response; fall back to dedicated endpoint
        var usageCap = invoiceResponse.limitDollars
        if usageCap <= 0 {
            let limitsURL = baseURL
                .appendingPathComponent("billing/teams/\(teamID)/postpaid/spending-limits")
            let limitsResponse: GrokSpendingLimitsResponse = try await Self.fetchJSON(
                url: limitsURL, bearerToken: managementKey)
            usageCap = limitsResponse.effectiveLimitDollars
        }

        let totalUsage = invoiceResponse.usageDollars
        let remaining = max(0, usageCap - totalUsage)
        let usedPercent = usageCap > 0 ? min(100, (totalUsage / usageCap) * 100) : 0

        return GrokBillingSnapshot(
            usageCap: usageCap,
            totalUsage: totalUsage,
            remaining: remaining,
            usedPercent: usedPercent,
            updatedAt: Date())
    }

    // MARK: Regular API (key status)

    /// Fetches API key info from xAI using the provided API key
    public static func fetchKeyStatus(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> GrokKeySnapshot
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GrokUsageError.missingAPIKey
        }

        let baseURL = GrokSettingsReader.apiURL(environment: environment)
        let keyURL = baseURL.appendingPathComponent("api-key")

        let keyResponse: GrokAPIKeyResponse = try await Self.fetchJSON(
            url: keyURL, bearerToken: apiKey)

        return GrokKeySnapshot(
            keyName: keyResponse.name,
            redactedKey: keyResponse.redactedApiKey,
            isActive: keyResponse.isActive,
            updatedAt: Date())
    }

    // MARK: Shared HTTP helper

    private static func fetchJSON<T: Decodable>(url: URL, bearerToken: String) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.requestTimeoutSeconds

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GrokUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            Self.log.error("xAI API returned \(httpResponse.statusCode): \(LogRedactor.redact(body))")
            throw GrokUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        } catch let error as DecodingError {
            Self.log.error("xAI JSON decoding error: \(error.localizedDescription)")
            throw GrokUsageError.parseFailed(error.localizedDescription)
        }
    }
}
