import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - API response types

public struct VeniceBalanceResponse: Decodable, Sendable {
    public let canConsume: Bool
    public let consumptionCurrency: String?
    public let balances: VeniceBalances
    public let diemEpochAllocation: Double?

    enum CodingKeys: String, CodingKey {
        case canConsume
        case consumptionCurrency
        case balances
        case diemEpochAllocation
    }
}

public struct VeniceBalances: Decodable, Sendable {
    public let diem: Double?
    public let usd: Double?

    enum CodingKeys: String, CodingKey {
        case diem
        case usd
    }
}

// MARK: - Domain snapshot

public struct VeniceUsageSnapshot: Sendable {
    public let canConsume: Bool
    public let consumptionCurrency: String?
    public let diemBalance: Double?
    public let usdBalance: Double?
    public let diemEpochAllocation: Double?
    public let updatedAt: Date

    public init(
        canConsume: Bool,
        consumptionCurrency: String?,
        diemBalance: Double?,
        usdBalance: Double?,
        diemEpochAllocation: Double?,
        updatedAt: Date)
    {
        self.canConsume = canConsume
        self.consumptionCurrency = consumptionCurrency
        self.diemBalance = diemBalance
        self.usdBalance = usdBalance
        self.diemEpochAllocation = diemEpochAllocation
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let balanceDetail: String
        let usedPercent: Double
        let activeCurrency = self.consumptionCurrency?.uppercased()

        if !self.canConsume {
            balanceDetail = "Balance unavailable for API calls"
            usedPercent = 100
        } else if activeCurrency == "USD", let usd = self.usdBalance, usd > 0 {
            let usdStr = String(format: "%.2f", usd)
            balanceDetail = "$\(usdStr) USD remaining"
            usedPercent = 0
        } else if activeCurrency == "DIEM", let diem = self.diemBalance, let allocation = self.diemEpochAllocation, allocation > 0 {
            // DIEM balance with epoch allocation
            let remaining = diem
            let usedAmount = allocation - remaining
            let used = clamp(usedAmount / allocation * 100, min: 0, max: 100)
            usedPercent = used
            let allocationStr = String(format: "%.2f", allocation)
            let remainingStr = String(format: "%.2f", remaining)
            balanceDetail = "DIEM \(remainingStr) / \(allocationStr) epoch allocation"
        } else if activeCurrency == "DIEM", let diem = self.diemBalance, diem > 0 {
            let diemStr = String(format: "%.2f", diem)
            balanceDetail = "DIEM \(diemStr) remaining"
            usedPercent = 0
        } else if let diem = self.diemBalance, diem > 0 {
            // DIEM balance without allocation
            let diemStr = String(format: "%.2f", diem)
            balanceDetail = "DIEM \(diemStr) remaining"
            usedPercent = 0
        } else if let usd = self.usdBalance, usd > 0 {
            // USD balance
            let usdStr = String(format: "%.2f", usd)
            balanceDetail = "$\(usdStr) USD remaining"
            usedPercent = 0
        } else {
            balanceDetail = "No Venice API balance available"
            usedPercent = 100
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .venice,
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

public enum VeniceUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Venice API key."
        case let .networkError(message):
            "Venice network error: \(message)"
        case let .apiError(message):
            "Venice API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Venice response: \(message)"
        }
    }
}

// MARK: - Fetcher

public struct VeniceUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.veniceUsage)
    private static let balanceURL = URL(string: "https://api.venice.ai/api/v1/billing/balance")!
    private static let timeoutSeconds: TimeInterval = 15

    public static func fetchUsage(apiKey: String) async throws -> VeniceUsageSnapshot {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VeniceUsageError.missingCredentials
        }

        var request = URLRequest(url: self.balanceURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VeniceUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            Self.log.error("Venice API returned \(httpResponse.statusCode)")
            throw VeniceUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        return try Self.parseSnapshot(data: data)
    }

    static func _parseSnapshotForTesting(_ data: Data) throws -> VeniceUsageSnapshot {
        try self.parseSnapshot(data: data)
    }

    private static func parseSnapshot(data: Data) throws -> VeniceUsageSnapshot {
        let decoded: VeniceBalanceResponse
        do {
            decoded = try JSONDecoder().decode(VeniceBalanceResponse.self, from: data)
        } catch {
            throw VeniceUsageError.parseFailed(error.localizedDescription)
        }

        return VeniceUsageSnapshot(
            canConsume: decoded.canConsume,
            consumptionCurrency: decoded.consumptionCurrency,
            diemBalance: decoded.balances.diem,
            usdBalance: decoded.balances.usd,
            diemEpochAllocation: decoded.diemEpochAllocation,
            updatedAt: Date())
    }
}

// MARK: - Helper

private func clamp(_ value: Double, min: Double, max: Double) -> Double {
    Swift.min(Swift.max(value, min), max)
}
