import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MiMoSettingsError: LocalizedError, Sendable {
    case missingCookie
    case invalidCookie

    public var errorDescription: String? {
        switch self {
        case .missingCookie:
            "No Xiaomi MiMo browser session found. Log in at platform.xiaomimimo.com first."
        case .invalidCookie:
            "Xiaomi MiMo requires the api-platform_serviceToken and userId cookies."
        }
    }
}

public enum MiMoUsageError: LocalizedError, Sendable {
    case invalidCredentials
    case loginRequired
    case parseFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Xiaomi MiMo browser session expired. Log in again."
        case .loginRequired:
            "Xiaomi MiMo login required."
        case let .parseFailed(message):
            "Could not parse Xiaomi MiMo balance: \(message)"
        case let .networkError(message):
            "Xiaomi MiMo request failed: \(message)"
        }
    }
}

public enum MiMoSettingsReader {
    public static let apiURLKey = "MIMO_API_URL"

    public static func apiURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[self.apiURLKey],
           let url = URL(string: override.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = url.scheme, !scheme.isEmpty
        {
            return url
        }
        return URL(string: "https://platform.xiaomimimo.com/api/v1")!
    }
}

public enum MiMoUsageFetcher {
    private static let requestTimeout: TimeInterval = 15

    public static func fetchUsage(
        cookieHeader: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) async throws -> MiMoUsageSnapshot
    {
        guard let normalizedCookie = MiMoCookieHeader.normalizedHeader(from: cookieHeader) else {
            throw MiMoSettingsError.invalidCookie
        }

        let balanceURL = MiMoSettingsReader.apiURL(environment: environment).appendingPathComponent("balance")
        let tokenDetailURL = MiMoSettingsReader.apiURL(environment: environment)
            .appendingPathComponent("tokenPlan/detail")
        let tokenUsageURL = MiMoSettingsReader.apiURL(environment: environment)
            .appendingPathComponent("tokenPlan/usage")

        async let balanceData = self.fetchAuthenticated(url: balanceURL, cookie: normalizedCookie)
        let tokenDetailData: Data? = try? await self.fetchAuthenticated(url: tokenDetailURL, cookie: normalizedCookie)
        let tokenUsageData: Data? = try? await self.fetchAuthenticated(url: tokenUsageURL, cookie: normalizedCookie)

        return try await self.parseCombinedSnapshot(
            balanceData: balanceData,
            tokenDetailData: tokenDetailData,
            tokenUsageData: tokenUsageData,
            now: now)
    }

    private static func fetchAuthenticated(
        url: URL,
        cookie: String,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> Data
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("UTC+01:00", forHTTPHeaderField: "x-timeZone")
        request.setValue("https://platform.xiaomimimo.com", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.xiaomimimo.com/#/console/balance", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MiMoUsageError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw MiMoUsageError.loginRequired
        case 403:
            throw MiMoUsageError.invalidCredentials
        default:
            throw MiMoUsageError.networkError("HTTP \(httpResponse.statusCode)")
        }

        return data
    }

    static func parseCombinedSnapshot(
        balanceData: Data,
        tokenDetailData: Data?,
        tokenUsageData: Data?,
        now: Date = Date()) throws -> MiMoUsageSnapshot
    {
        let balanceSnapshot = try self.parseUsageSnapshot(from: balanceData, now: now)
        let planDetail: (planCode: String?, periodEnd: Date?, expired: Bool) = {
            guard let data = tokenDetailData, let result = try? self.parseTokenPlanDetail(from: data) else {
                return (planCode: nil, periodEnd: nil, expired: false)
            }
            return result
        }()
        let planUsage: (used: Int, limit: Int, percent: Double) = {
            guard let data = tokenUsageData, let result = try? self.parseTokenPlanUsage(from: data) else {
                return (used: 0, limit: 0, percent: 0)
            }
            return result
        }()

        return MiMoUsageSnapshot(
            balance: balanceSnapshot.balance,
            currency: balanceSnapshot.currency,
            planCode: planDetail.planCode,
            planPeriodEnd: planDetail.periodEnd,
            planExpired: planDetail.expired,
            tokenUsed: planUsage.used,
            tokenLimit: planUsage.limit,
            tokenPercent: planUsage.percent,
            updatedAt: now)
    }

    static func parseUsageSnapshot(from data: Data, now: Date = Date()) throws -> MiMoUsageSnapshot {
        let decoder = JSONDecoder()
        let response = try decoder.decode(BalanceResponse.self, from: data)

        guard response.code == 0 else {
            let message = response.message?.trimmingCharacters(in: .whitespacesAndNewlines)
            if response.code == 401 {
                throw MiMoUsageError.loginRequired
            }
            if response.code == 403 {
                throw MiMoUsageError.invalidCredentials
            }
            throw MiMoUsageError.parseFailed(message?.isEmpty == false ? message! : "code \(response.code)")
        }

        guard let data = response.data else {
            throw MiMoUsageError.parseFailed("Missing balance payload")
        }
        guard let balance = Double(data.balance) else {
            throw MiMoUsageError.parseFailed("Invalid balance value")
        }

        let currency = data.currency.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currency.isEmpty else {
            throw MiMoUsageError.parseFailed("Missing currency")
        }

        return MiMoUsageSnapshot(balance: balance, currency: currency, updatedAt: now)
    }

    static func parseTokenPlanDetail(from data: Data) throws -> (planCode: String?, periodEnd: Date?, expired: Bool) {
        let decoder = JSONDecoder()
        let response = try decoder.decode(TokenPlanDetailResponse.self, from: data)

        guard response.code == 0, let payload = response.data else {
            return (planCode: nil, periodEnd: nil, expired: false)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        let periodEnd: Date? = if let dateStr = payload.currentPeriodEnd {
            formatter.date(from: dateStr)
        } else {
            nil
        }

        return (planCode: payload.planCode, periodEnd: periodEnd, expired: payload.expired)
    }

    static func parseTokenPlanUsage(from data: Data) throws -> (used: Int, limit: Int, percent: Double) {
        let decoder = JSONDecoder()
        let response = try decoder.decode(TokenPlanUsageResponse.self, from: data)

        guard response.code == 0,
              let monthUsage = response.data?.monthUsage,
              let item = monthUsage.items.first
        else {
            return (used: 0, limit: 0, percent: 0)
        }

        return (used: item.used, limit: item.limit, percent: item.percent)
    }

    private struct BalanceResponse: Decodable {
        let code: Int
        let message: String?
        let data: BalancePayload?
    }

    private struct BalancePayload: Decodable {
        let balance: String
        let currency: String
    }

    private struct TokenPlanDetailResponse: Decodable {
        let code: Int
        let message: String?
        let data: TokenPlanDetailPayload?
    }

    private struct TokenPlanDetailPayload: Decodable {
        let planCode: String?
        let currentPeriodEnd: String?
        let expired: Bool
    }

    private struct TokenPlanUsageResponse: Decodable {
        let code: Int
        let message: String?
        let data: TokenPlanUsagePayload?
    }

    private struct TokenPlanUsagePayload: Decodable {
        let monthUsage: MonthUsage?
    }

    private struct MonthUsage: Decodable {
        let percent: Double
        let items: [UsageItem]
    }

    private struct UsageItem: Decodable {
        let name: String
        let used: Int
        let limit: Int
        let percent: Double
    }
}
