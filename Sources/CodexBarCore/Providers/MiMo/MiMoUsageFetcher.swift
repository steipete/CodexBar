import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MiMoSettingsError: LocalizedError, Sendable, Equatable {
    case missingCookie(details: String? = nil)
    case invalidCookie
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case let .missingCookie(details):
            [
                "No Xiaomi MiMo browser session found. Log in at platform.xiaomimimo.com first.",
                details,
            ]
                .compactMap(\.self)
                .joined(separator: " ")
        case .invalidCookie:
            "Xiaomi MiMo requires the api-platform_serviceToken and userId cookies."
        case let .invalidEndpointOverride(key):
            "Xiaomi MiMo endpoint override \(key) must use HTTPS or a bare host."
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
        if let override = self.cleaned(environment[self.apiURLKey]),
           let url = ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: override)
        {
            return url
        }
        return URL(string: "https://platform.xiaomimimo.com/api/v1")!
    }

    public static func validateEndpointOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard let override = self.cleaned(environment[self.apiURLKey]) else { return }
        guard ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: override) == nil else { return }
        throw MiMoSettingsError.invalidEndpointOverride(self.apiURLKey)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

public enum MiMoUsageFetcher {
    private static let requestTimeout: TimeInterval = 15

    public static func fetchUsage(
        cookieHeader: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> MiMoUsageSnapshot
    {
        guard let normalizedCookie = MiMoCookieHeader.normalizedHeader(from: cookieHeader) else {
            throw MiMoSettingsError.invalidCookie
        }
        try MiMoSettingsReader.validateEndpointOverrides(environment: environment)

        let balanceURL = MiMoSettingsReader.apiURL(environment: environment).appendingPathComponent("balance")
        let tokenDetailURL = MiMoSettingsReader.apiURL(environment: environment)
            .appendingPathComponent("tokenPlan/detail")
        let tokenUsageURL = MiMoSettingsReader.apiURL(environment: environment)
            .appendingPathComponent("tokenPlan/usage")

        let payloads = try await self.fetchPayloads(
            balanceURL: balanceURL,
            tokenDetailURL: tokenDetailURL,
            tokenUsageURL: tokenUsageURL,
            cookie: normalizedCookie,
            transport: transport)

        return try self.parseCombinedSnapshot(
            balanceData: payloads.balance,
            tokenDetailData: payloads.tokenDetail,
            tokenUsageData: payloads.tokenUsage,
            now: now)
    }

    private enum FetchPart {
        case balance(Data)
        case tokenDetail(Data?)
        case tokenUsage(Data?)
    }

    private static func fetchPayloads(
        balanceURL: URL,
        tokenDetailURL: URL,
        tokenUsageURL: URL,
        cookie: String,
        transport: any ProviderHTTPTransport) async throws -> (balance: Data, tokenDetail: Data?, tokenUsage: Data?)
    {
        try await withThrowingTaskGroup(of: FetchPart.self) { group in
            group.addTask {
                try await .balance(self.fetchAuthenticated(
                    url: balanceURL,
                    cookie: cookie,
                    transport: transport))
            }
            group.addTask {
                await .tokenDetail(try? self.fetchAuthenticated(
                    url: tokenDetailURL,
                    cookie: cookie,
                    transport: transport))
            }
            group.addTask {
                await .tokenUsage(try? self.fetchAuthenticated(
                    url: tokenUsageURL,
                    cookie: cookie,
                    transport: transport))
            }

            var balance: Data?
            var tokenDetail: Data?
            var tokenUsage: Data?

            while let part = try await group.next() {
                switch part {
                case let .balance(data):
                    balance = data
                case let .tokenDetail(data):
                    tokenDetail = data
                case let .tokenUsage(data):
                    tokenUsage = data
                }
            }

            guard let balance else {
                throw MiMoUsageError.networkError("Balance request did not complete")
            }
            return (balance, tokenDetail, tokenUsage)
        }
    }

    private static func fetchAuthenticated(
        url: URL,
        cookie: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> Data
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

        let response = try await transport.response(for: request)

        switch response.statusCode {
        case 200:
            break
        // Expired browser sessions can redirect API requests to the login flow.
        case 300..<400:
            throw MiMoUsageError.loginRequired
        case 401:
            throw MiMoUsageError.loginRequired
        case 403:
            throw MiMoUsageError.invalidCredentials
        default:
            throw MiMoUsageError.networkError("HTTP \(response.statusCode)")
        }

        return response.data
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
            cashBalance: balanceSnapshot.cashBalance,
            giftBalance: balanceSnapshot.giftBalance,
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
        let cashBalance = data.cashBalance.flatMap(Double.init)
        let giftBalance = data.giftBalance.flatMap(Double.init)

        let currency = data.currency.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currency.isEmpty else {
            throw MiMoUsageError.parseFailed("Missing currency")
        }

        return MiMoUsageSnapshot(
            balance: balance,
            currency: currency,
            cashBalance: cashBalance,
            giftBalance: giftBalance,
            updatedAt: now)
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
        let cashBalance: String?
        let giftBalance: String?
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
