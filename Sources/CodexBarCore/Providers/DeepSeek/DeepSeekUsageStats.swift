import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// DeepSeek balance API response
public struct DeepSeekBalanceInfo: Decodable, Sendable {
    public let currency: String
    public let totalBalance: String
    public let toppedUpBalance: String
    public let grantedBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case toppedUpBalance = "topped_up_balance"
        case grantedBalance = "granted_balance"
    }
}

public struct DeepSeekBalanceResponse: Decodable, Sendable {
    public let isAvailable: Bool
    public let balanceInfos: [DeepSeekBalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

/// Complete DeepSeek usage snapshot
public struct DeepSeekUsageSnapshot: Sendable {
    public let totalBalance: Double
    public let toppedUpBalance: Double
    public let grantedBalance: Double
    public let currency: String
    public let isAvailable: Bool
    public let updatedAt: Date

    public init(
        totalBalance: Double,
        toppedUpBalance: Double,
        grantedBalance: Double,
        currency: String,
        isAvailable: Bool,
        updatedAt: Date)
    {
        self.totalBalance = totalBalance
        self.toppedUpBalance = toppedUpBalance
        self.grantedBalance = grantedBalance
        self.currency = currency
        self.isAvailable = isAvailable
        self.updatedAt = updatedAt
    }

    public var isValid: Bool {
        self.totalBalance >= 0
    }
}

extension DeepSeekUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let balanceStr = String(format: "%.2f %@", totalBalance, currency)
        let identity = ProviderIdentitySnapshot(
            providerID: .deepseek,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Balance: \(balanceStr)")

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

/// Fetches usage stats from the DeepSeek API
public struct DeepSeekUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.deepSeekUsage)
    private static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    private static let requestTimeoutSeconds: TimeInterval = 15
    private static let maxErrorBodyLength = 240

    public static func fetchUsage(apiKey: String) async throws -> DeepSeekUsageSnapshot {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepSeekUsageError.missingCredentials
        }

        var request = URLRequest(url: self.balanceURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.requestTimeoutSeconds

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepSeekUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorSummary = LogRedactor.redact(Self.sanitizedResponseBodySummary(data))
            Self.log.error("DeepSeek API returned \(httpResponse.statusCode): \(errorSummary)")
            throw DeepSeekUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        do {
            let decoder = JSONDecoder()
            let balanceResponse = try decoder.decode(DeepSeekBalanceResponse.self, from: data)

            let totalBalance = balanceResponse.balanceInfos.reduce(0.0) { sum, info in
                sum + (Double(info.totalBalance) ?? 0)
            }
            let toppedUp = balanceResponse.balanceInfos.reduce(0.0) { sum, info in
                sum + (Double(info.toppedUpBalance) ?? 0)
            }
            let granted = balanceResponse.balanceInfos.reduce(0.0) { sum, info in
                sum + (Double(info.grantedBalance) ?? 0)
            }
            let currency = balanceResponse.balanceInfos.first?.currency ?? "CNY"

            return DeepSeekUsageSnapshot(
                totalBalance: totalBalance,
                toppedUpBalance: toppedUp,
                grantedBalance: granted,
                currency: currency,
                isAvailable: balanceResponse.isAvailable,
                updatedAt: Date())
        } catch let error as DeepSeekUsageError {
            throw error
        } catch {
            Self.log.error("DeepSeek parsing error: \(error.localizedDescription)")
            throw DeepSeekUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func sanitizedResponseBodySummary(_ data: Data) -> String {
        guard !data.isEmpty else { return "empty body" }
        guard let rawBody = String(bytes: data, encoding: .utf8) else {
            return "non-text body (\(data.count) bytes)"
        }

        let body = rawBody
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "non-text body (\(data.count) bytes)" }
        guard body.count > Self.maxErrorBodyLength else { return body }

        let index = body.index(body.startIndex, offsetBy: Self.maxErrorBodyLength)
        return "\(body[..<index])… [truncated]"
    }

    #if DEBUG
    static func _sanitizedResponseBodySummaryForTesting(_ body: String) -> String {
        self.sanitizedResponseBodySummary(Data(body.utf8))
    }
    #endif
}

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
