import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - API response types

public struct DeepSeekBalanceResponse: Decodable, Sendable {
    public let isAvailable: Bool
    public let balanceInfos: [DeepSeekBalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

public struct DeepSeekBalanceInfo: Decodable, Sendable {
    public let currency: String
    public let totalBalance: String
    public let grantedBalance: String
    public let toppedUpBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}

// MARK: - Domain snapshot

public struct DeepSeekUsageSnapshot: Sendable {
    public let isAvailable: Bool
    public let currency: String
    public let totalBalance: Double
    public let grantedBalance: Double
    public let toppedUpBalance: Double
    public let updatedAt: Date

    public init(
        isAvailable: Bool,
        currency: String,
        totalBalance: Double,
        grantedBalance: Double,
        toppedUpBalance: Double,
        updatedAt: Date)
    {
        self.isAvailable = isAvailable
        self.currency = currency
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = toppedUpBalance
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let symbol = self.currency == "CNY" ? "¥" : "$"

        let balanceDetail: String
        let usedPercent: Double
        if self.totalBalance <= 0 {
            balanceDetail = "\(symbol)0.00 — add credits at platform.deepseek.com"
            usedPercent = 100
        } else if !self.isAvailable {
            balanceDetail = "Balance unavailable for API calls"
            usedPercent = 100
        } else {
            let total = String(format: "\(symbol)%.2f", self.totalBalance)
            let paid = String(format: "\(symbol)%.2f", self.toppedUpBalance)
            let granted = String(format: "\(symbol)%.2f", self.grantedBalance)
            balanceDetail = "\(total) (Paid: \(paid) / Granted: \(granted))"
            usedPercent = 0
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .deepseek,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)
        let balanceWindow = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: balanceDetail)

        return UsageSnapshot(
            primary: balanceWindow,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

// MARK: - Errors

public enum DeepSeekUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing DeepSeek API key."
        case let .networkError(message):
            "DeepSeek network error: \(message)"
        case let .apiError(message):
            "DeepSeek API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse DeepSeek response: \(message)"
        }
    }
}

// MARK: - Fetcher

public struct DeepSeekUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.deepSeekUsage)
    private static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    private static let timeoutSeconds: TimeInterval = 15

    public static func fetchUsage(apiKey: String) async throws -> DeepSeekUsageSnapshot {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepSeekUsageError.missingCredentials
        }

        var request = URLRequest(url: self.balanceURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepSeekUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("DeepSeek API returned \(httpResponse.statusCode): \(body)")
            throw DeepSeekUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        if let jsonString = String(data: data, encoding: .utf8) {
            Self.log.debug("DeepSeek API response: \(jsonString)")
        }

        return try Self.parseSnapshot(data: data)
    }

    static func _parseSnapshotForTesting(_ data: Data) throws -> DeepSeekUsageSnapshot {
        try self.parseSnapshot(data: data)
    }

    private static func parseSnapshot(data: Data) throws -> DeepSeekUsageSnapshot {
        let decoded: DeepSeekBalanceResponse
        do {
            decoded = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
        } catch {
            throw DeepSeekUsageError.parseFailed(error.localizedDescription)
        }

        let balances = try decoded.balanceInfos.map(Self.parseBalanceInfo)
        guard !balances.isEmpty else {
            return DeepSeekUsageSnapshot(
                isAvailable: false,
                currency: "USD",
                totalBalance: 0,
                grantedBalance: 0,
                toppedUpBalance: 0,
                updatedAt: Date())
        }

        // Prefer USD when it is funded, but do not hide a positive CNY balance behind
        // an empty USD row returned by the API.
        let selected = balances.first { $0.currency == "USD" && $0.totalBalance > 0 }
            ?? balances.first { $0.totalBalance > 0 }
            ?? balances.first { $0.currency == "USD" }
            ?? balances[0]

        return DeepSeekUsageSnapshot(
            isAvailable: decoded.isAvailable,
            currency: selected.currency,
            totalBalance: selected.totalBalance,
            grantedBalance: selected.grantedBalance,
            toppedUpBalance: selected.toppedUpBalance,
            updatedAt: Date())
    }

    private struct ParsedBalanceInfo {
        let currency: String
        let totalBalance: Double
        let grantedBalance: Double
        let toppedUpBalance: Double
    }

    private static func parseBalanceInfo(_ info: DeepSeekBalanceInfo) throws -> ParsedBalanceInfo {
        guard
            let total = Double(info.totalBalance),
            let granted = Double(info.grantedBalance),
            let toppedUp = Double(info.toppedUpBalance)
        else {
            throw DeepSeekUsageError.parseFailed("Non-numeric balance value in response.")
        }

        return ParsedBalanceInfo(
            currency: info.currency,
            totalBalance: total,
            grantedBalance: granted,
            toppedUpBalance: toppedUp)
    }
}
