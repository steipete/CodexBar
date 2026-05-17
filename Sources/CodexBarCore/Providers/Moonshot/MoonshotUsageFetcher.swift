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

    public init(
        availableBalance: Double, voucherBalance: Double, cashBalance: Double, updatedAt: Date)
    {
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

private struct MoonshotBalanceResponse: Decodable {
    let code: Int
    let data: MoonshotBalanceData
    let scode: String
    let status: Bool
}

private struct MoonshotBalanceData: Decodable {
    let availableBalance: Double
    let voucherBalance: Double
    let cashBalance: Double

    private enum CodingKeys: String, CodingKey {
        case availableBalance = "available_balance"
        case voucherBalance = "voucher_balance"
        case cashBalance = "cash_balance"
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
    private static let timeoutSeconds: TimeInterval = 15

    public static func fetchUsage(
        apiKey: String,
        region: MoonshotRegion = .international,
        session: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> MoonshotUsageSnapshot
    {
        let cleaned = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw MoonshotUsageError.missingCredentials
        }

        var request = URLRequest(url: self.resolveBalanceURL(region: region))
        request.httpMethod = "GET"
        request.setValue("Bearer \(cleaned)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MoonshotUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            Self.log.error("Moonshot API returned HTTP \(httpResponse.statusCode)")
            throw MoonshotUsageError.apiError("HTTP \(httpResponse.statusCode)")
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
        let response: MoonshotBalanceResponse
        do {
            response = try JSONDecoder().decode(MoonshotBalanceResponse.self, from: data)
        } catch {
            throw MoonshotUsageError.parseFailed(error.localizedDescription)
        }

        guard response.code == 0, response.status else {
            throw MoonshotUsageError.apiError("code \(response.code), scode \(response.scode)")
        }

        return MoonshotUsageSummary(
            availableBalance: response.data.availableBalance,
            voucherBalance: response.data.voucherBalance,
            cashBalance: response.data.cashBalance,
            updatedAt: Date())
    }
}
