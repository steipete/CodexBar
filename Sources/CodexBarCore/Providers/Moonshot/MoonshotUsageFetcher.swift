import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MoonshotUsageSnapshot: Sendable {
    public let summary: MoonshotUsageSummary

    public init(summary: MoonshotUsageSummary) {
        self.summary = summary
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        self.summary.toUsageSnapshot()
    }
}

public struct MoonshotUsageSummary: Sendable {
    public let availableBalance: Double
    public let voucherBalance: Double
    public let cashBalance: Double
    public let updatedAt: Date

    public init(availableBalance: Double, voucherBalance: Double, cashBalance: Double, updatedAt: Date) {
        self.availableBalance = availableBalance
        self.voucherBalance = voucherBalance
        self.cashBalance = cashBalance
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let balance = UsageFormatter.usdString(self.availableBalance)
        let loginMethod: String
        if self.cashBalance < 0 {
            let deficit = UsageFormatter.usdString(abs(self.cashBalance))
            loginMethod = "Balance: \(balance) · \(deficit) in deficit"
        } else {
            loginMethod = "Balance: \(balance)"
        }
        let identity = ProviderIdentitySnapshot(
            providerID: .moonshot,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginMethod)
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

public enum MoonshotUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Moonshot API key."
        case let .networkError(message):
            "Moonshot network error: \(message)"
        case let .apiError(message):
            "Moonshot API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Moonshot response: \(message)"
        }
    }
}

public struct MoonshotUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.moonshotUsage)

    public static func fetchUsage(
        apiKey: String,
        region: MoonshotRegion = .international,
        session: URLSession = .shared) async throws -> MoonshotUsageSnapshot
    {
        let cleaned = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw MoonshotUsageError.missingCredentials
        }

        var request = URLRequest(url: self.resolveBalanceURL(region: region))
        request.httpMethod = "GET"
        request.setValue("Bearer \(cleaned)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MoonshotUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            Self.log.error("Moonshot API returned \(httpResponse.statusCode): \(body)")
            throw MoonshotUsageError.apiError(body)
        }

        let summary = try self.parseSummary(data: data)
        return MoonshotUsageSnapshot(summary: summary)
    }

    public static func resolveBalanceURL(region: MoonshotRegion) -> URL {
        region.balanceURL
    }

    static func _parseSummaryForTesting(_ data: Data) throws -> MoonshotUsageSummary {
        try self.parseSummary(data: data)
    }

    private static func parseSummary(data: Data) throws -> MoonshotUsageSummary {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let dictionary = json as? [String: Any]
        else {
            throw MoonshotUsageError.parseFailed("Root JSON is not an object.")
        }

        guard let payload = dictionary["data"] as? [String: Any] else {
            throw MoonshotUsageError.parseFailed("Missing data object.")
        }
        guard let availableBalance = self.double(from: payload["available_balance"]) else {
            throw MoonshotUsageError.parseFailed("Missing available_balance.")
        }
        guard let voucherBalance = self.double(from: payload["voucher_balance"]) else {
            throw MoonshotUsageError.parseFailed("Missing voucher_balance.")
        }
        guard let cashBalance = self.double(from: payload["cash_balance"]) else {
            throw MoonshotUsageError.parseFailed("Missing cash_balance.")
        }

        return MoonshotUsageSummary(
            availableBalance: availableBalance,
            voucherBalance: voucherBalance,
            cashBalance: cashBalance,
            updatedAt: Date())
    }

    private static func double(from raw: Any?) -> Double? {
        if let value = raw as? Double {
            return value
        }
        if let value = raw as? Int {
            return Double(value)
        }
        if let value = raw as? String {
            return Double(value)
        }
        return nil
    }
}
