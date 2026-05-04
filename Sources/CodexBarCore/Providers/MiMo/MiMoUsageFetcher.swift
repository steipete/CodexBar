import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Domain snapshot

public struct MiMoUsageSnapshot: Sendable {
    public let isConnected: Bool
    public let modelCount: Int
    public let modelNames: [String]
    public let balanceInfo: MiMoBalanceInfo?
    public let updatedAt: Date

    public init(
        isConnected: Bool,
        modelCount: Int,
        modelNames: [String],
        balanceInfo: MiMoBalanceInfo? = nil,
        updatedAt: Date)
    {
        self.isConnected = isConnected
        self.modelCount = modelCount
        self.modelNames = modelNames
        self.balanceInfo = balanceInfo
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let detail: String
        let usedPercent: Double
        if let balance = self.balanceInfo {
            let remaining = balance.availableBalance
            let total = balance.totalBalance
            usedPercent = total > 0 ? max(0, min(100, (total - remaining) / total * 100)) : 0
            detail = String(format: "¥%.2f / ¥%.2f", remaining, total)
        } else if self.isConnected {
            let names = self.modelNames.joined(separator: ", ")
            detail = "API Connected — \(self.modelCount) models (\(names))"
            usedPercent = 0
        } else {
            detail = "API not connected"
            usedPercent = 100
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .mimo,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)

        let primaryWindow = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: detail)

        var secondaryWindow: RateWindow?
        if let balance = self.balanceInfo {
            secondaryWindow = RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "Used: ¥\(String(format: "%.2f", balance.usedBalance))")
        }

        let providerCost: ProviderCostSnapshot?
        if let balance = self.balanceInfo {
            providerCost = ProviderCostSnapshot(
                used: balance.usedBalance,
                limit: balance.totalBalance,
                currencyCode: "CNY",
                period: nil,
                resetsAt: nil,
                updatedAt: self.updatedAt)
        } else {
            providerCost = nil
        }

        return UsageSnapshot(
            primary: primaryWindow,
            secondary: secondaryWindow,
            tertiary: nil,
            providerCost: providerCost,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

public struct MiMoBalanceInfo: Sendable {
    public let availableBalance: Double
    public let usedBalance: Double
    public let totalBalance: Double

    public init(availableBalance: Double, usedBalance: Double, totalBalance: Double) {
        self.availableBalance = availableBalance
        self.usedBalance = usedBalance
        self.totalBalance = totalBalance
    }
}

// MARK: - Errors

public enum MiMoUsageError: LocalizedError, Sendable {
    case missingCredentials
    case missingCookie
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing MiMo API key."
        case .missingCookie:
            "Missing MiMo session cookie."
        case let .networkError(message):
            "MiMo network error: \(message)"
        case let .apiError(message):
            "MiMo API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse MiMo response: \(message)"
        }
    }
}

// MARK: - Fetcher

public struct MiMoUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.mimoUsage)
    private static let webLog = CodexBarLog.logger(LogCategories.mimoWeb)
    private static let baseURL = URL(string: "https://api.xiaomimimo.com/v1")!
    private static let balanceURL =
        URL(string: "https://platform.xiaomimimo.com/api/user/balance")!

    public static func verifyAPI(apiKey: String) async throws -> MiMoUsageSnapshot {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MiMoUsageError.missingCredentials
        }

        let modelsURL = self.baseURL.appendingPathComponent("models")
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        // MiMo 使用 api-key header 而非 Authorization: Bearer
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MiMoUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("MiMo API returned \(httpResponse.statusCode): \(body)")
            throw MiMoUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        return try self.parseModelsResponse(data: data)
    }

    public static func fetchBalance(
        cookieHeader: String,
        now: Date = Date()) async throws -> MiMoUsageSnapshot
    {
        var request = URLRequest(url: self.balanceURL)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://platform.xiaomimimo.com/console/balance", forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MiMoUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            Self.webLog.error("MiMo balance API returned \(httpResponse.statusCode): \(body)")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw MiMoUsageError.apiError("Cookie expired or invalid")
            }
            throw MiMoUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        let balanceInfo = try self.parseBalanceResponse(data: data)
        return MiMoUsageSnapshot(
            isConnected: true,
            modelCount: 0,
            modelNames: [],
            balanceInfo: balanceInfo,
            updatedAt: now)
    }

    static func _parseBalanceForTesting(_ data: Data) throws -> MiMoBalanceInfo {
        try self.parseBalanceResponse(data: data)
    }

    static func _parseModelsForTesting(_ data: Data) throws -> MiMoUsageSnapshot {
        try self.parseModelsResponse(data: data)
    }

    private static func parseModelsResponse(data: Data) throws -> MiMoUsageSnapshot {
        let decoded: ModelsResponse
        do {
            decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        } catch {
            throw MiMoUsageError.parseFailed(error.localizedDescription)
        }

        let modelNames = decoded.data.prefix(5).map(\.id)
        return MiMoUsageSnapshot(
            isConnected: true,
            modelCount: decoded.data.count,
            modelNames: Array(modelNames),
            updatedAt: Date())
    }

    private static func parseBalanceResponse(data: Data) throws -> MiMoBalanceInfo {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MiMoUsageError.parseFailed("Invalid JSON")
        }

        // Try "data" wrapper first
        let root = (json["data"] as? [String: Any]) ?? json

        let available = self.extractDouble(from: root, keys: [
            "available_balance", "availableBalance", "available_quota",
            "remain_quota", "balance", "remain"])
        let used = self.extractDouble(from: root, keys: [
            "used_balance", "usedBalance", "used_quota", "used"])
        let total = self.extractDouble(from: root, keys: [
            "total_balance", "totalBalance", "total_quota", "total", "quota"])

        let totalBalance = total ?? (available ?? 0) + (used ?? 0)

        return MiMoBalanceInfo(
            availableBalance: available ?? 0,
            usedBalance: used ?? max(0, totalBalance - (available ?? 0)),
            totalBalance: totalBalance)
    }

    private static func extractDouble(from dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = dict[key] {
                if let d = value as? Double { return d }
                if let i = value as? Int { return Double(i) }
                if let s = value as? String, let d = Double(s) { return d }
            }
        }
        return nil
    }
}

// MARK: - API response types

private struct ModelsResponse: Decodable, Sendable {
    let data: [ModelEntry]
}

private struct ModelEntry: Decodable, Sendable {
    let id: String
}
