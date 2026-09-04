import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HelmcodeModelQuota: Decodable, Equatable, Sendable {
    public let model: String
    public let cap: Int64
    public let tokensUsed: Int64
    public let creditTokens: Int64?
    public let creditSpendMicros: Int64?
}

public struct HelmcodeQuotaResponse: Decodable, Equatable, Sendable {
    public let periodStart: String
    public let models: [HelmcodeModelQuota]
}

public struct HelmcodeCreditsResponse: Decodable, Equatable, Sendable {
    public let balanceMicros: Int64
    public let currency: String

    private enum CodingKeys: String, CodingKey {
        case balanceMicros
        case currency
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.balanceMicros = try container.decode(Int64.self, forKey: .balanceMicros)
        self.currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? "EUR"
    }
}

public struct HelmcodeUsageSnapshot: Equatable, Sendable {
    public let quota: HelmcodeQuotaResponse
    public let credits: HelmcodeCreditsResponse?
    public let updatedAt: Date

    public init(quota: HelmcodeQuotaResponse, credits: HelmcodeCreditsResponse?, updatedAt: Date) {
        self.quota = quota
        self.credits = credits
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let resetAt = Self.nextMonthStart(periodStart: self.quota.periodStart)
        let metered = self.quota.models
            .filter { $0.cap > 0 }
            .sorted { lhs, rhs in
                let lhsPercent = Double(lhs.tokensUsed) / Double(lhs.cap)
                let rhsPercent = Double(rhs.tokensUsed) / Double(rhs.cap)
                if lhsPercent != rhsPercent { return lhsPercent > rhsPercent }
                return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
            }
        let namedWindows = metered.map { quota in
            NamedRateWindow(
                id: "helmcode-\(quota.model)",
                title: quota.model,
                window: Self.rateWindow(quota, resetAt: resetAt))
        }
        let primary = namedWindows.first?.window
        let extras = namedWindows.dropFirst()

        let providerCost = self.credits.map { credits in
            ProviderCostSnapshot(
                used: max(0, Double(credits.balanceMicros) / 1_000_000),
                limit: 0,
                currencyCode: credits.currency.uppercased(),
                period: "Prepaid balance",
                updatedAt: self.updatedAt)
        }

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: extras.isEmpty ? nil : Array(extras),
            providerCost: providerCost,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .helmcode,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Dashboard session"),
            dataConfidence: .exact)
    }

    private static func rateWindow(_ quota: HelmcodeModelQuota, resetAt: Date?) -> RateWindow {
        let percent = min(100, max(0, Double(quota.tokensUsed) / Double(quota.cap) * 100))
        var detail = "\(quota.model) · \(Self.formatTokens(quota.tokensUsed)) / " +
            "\(Self.formatTokens(quota.cap)) tokens"
        if let creditTokens = quota.creditTokens, creditTokens > 0 {
            detail += " · \(Self.formatTokens(creditTokens)) credit-funded"
        }
        return RateWindow(
            usedPercent: percent,
            windowMinutes: nil,
            resetsAt: resetAt,
            resetDescription: detail)
    }

    private static func formatTokens(_ value: Int64) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    static func nextMonthStart(periodStart: String) -> Date? {
        let prefix = String(periodStart.prefix(10))
        let pieces = prefix.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let start = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: pieces[0],
            month: pieces[1],
            day: 1))
        else {
            return nil
        }
        return calendar.date(byAdding: .month, value: 1, to: start)
    }
}

public enum HelmcodeUsageError: LocalizedError, Equatable, Sendable {
    case missingCookies
    case invalidSession
    case rateLimited
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCookies:
            "No Helmcode dashboard session found. Sign in at cloud.helmcode.com or paste a Cookie header."
        case .invalidSession:
            "Helmcode dashboard session expired. Sign in again at cloud.helmcode.com."
        case .rateLimited:
            "Helmcode rate limit exceeded. Usage will refresh on the next cycle."
        case let .apiError(statusCode):
            "Helmcode dashboard API returned HTTP \(statusCode)."
        case let .parseFailed(message):
            "Could not parse Helmcode usage: \(message)"
        }
    }
}

public struct HelmcodeUsageFetcher: Sendable {
    public static let quotaURL = URL(string: "https://cloud-api.helmcode.com/api/usage/quota")!
    public static let creditsURL = URL(string: "https://cloud-api.helmcode.com/api/billing/credits")!
    private static let dashboardURL = URL(string: "https://cloud.helmcode.com/credits")!
    private static let timeoutSeconds: TimeInterval = 15
    private static let log = CodexBarLog.logger(LogCategories.provider(.helmcode, scope: "usage"))

    private enum Authentication: @unchecked Sendable {
        case header(String)
        case cookies([HTTPCookie])

        func header(for url: URL) -> String? {
            switch self {
            case let .header(value):
                CookieHeaderNormalizer.normalize(value)
            case let .cookies(cookies):
                HelmcodeCookieHeader.header(from: cookies, for: url)
            }
        }
    }

    private static let defaultTransport: ProviderHTTPClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return ProviderHTTPClient(session: ProviderHTTPClient.redirectGuardedSession(configuration: configuration))
    }()

    public static func fetchUsage(
        cookieHeader: String,
        transport transportOverride: (any ProviderHTTPTransport)? = nil,
        now: Date = Date()) async throws -> HelmcodeUsageSnapshot
    {
        try await self.fetchUsage(
            authentication: .header(cookieHeader),
            transport: transportOverride ?? self.defaultTransport,
            now: now)
    }

    static func fetchUsage(
        cookies: [HTTPCookie],
        transport transportOverride: (any ProviderHTTPTransport)? = nil,
        now: Date = Date()) async throws -> HelmcodeUsageSnapshot
    {
        try await self.fetchUsage(
            authentication: .cookies(cookies),
            transport: transportOverride ?? self.defaultTransport,
            now: now)
    }

    static func _parseSnapshotForTesting(
        quotaData: Data,
        creditsData: Data?,
        now: Date = Date()) throws -> HelmcodeUsageSnapshot
    {
        try self.parseSnapshot(quotaData: quotaData, creditsData: creditsData, now: now)
    }

    private static func fetchUsage(
        authentication: Authentication,
        transport: any ProviderHTTPTransport,
        now: Date) async throws -> HelmcodeUsageSnapshot
    {
        guard authentication.header(for: self.quotaURL) != nil else {
            throw HelmcodeUsageError.missingCookies
        }

        let quotaData = try await self.get(
            self.quotaURL,
            authentication: authentication,
            transport: transport)
        var creditsData: Data?
        do {
            creditsData = try await self.get(
                self.creditsURL,
                authentication: authentication,
                transport: transport)
        } catch is CancellationError {
            throw CancellationError()
        } catch HelmcodeUsageError.invalidSession {
            throw HelmcodeUsageError.invalidSession
        } catch {
            self.log.info("Helmcode credit balance unavailable (non-fatal): \(error.localizedDescription)")
        }
        return try self.parseSnapshot(quotaData: quotaData, creditsData: creditsData, now: now)
    }

    private static func get(
        _ url: URL,
        authentication: Authentication,
        transport: any ProviderHTTPTransport) async throws -> Data
    {
        guard let cookieHeader = authentication.header(for: url) else {
            throw HelmcodeUsageError.missingCookies
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://cloud.helmcode.com", forHTTPHeaderField: "Origin")
        request.setValue(self.dashboardURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = self.timeoutSeconds

        let response = try await transport.response(for: request, retryPolicy: .transientIdempotent)
        switch response.statusCode {
        case 200:
            return response.data
        case 300...399, 401, 403:
            throw HelmcodeUsageError.invalidSession
        case 429:
            throw HelmcodeUsageError.rateLimited
        default:
            throw HelmcodeUsageError.apiError(response.statusCode)
        }
    }

    private static func parseSnapshot(
        quotaData: Data,
        creditsData: Data?,
        now: Date) throws -> HelmcodeUsageSnapshot
    {
        let decoder = JSONDecoder()
        let quota: HelmcodeQuotaResponse
        do {
            quota = try decoder.decode(HelmcodeQuotaResponse.self, from: quotaData)
        } catch {
            throw HelmcodeUsageError.parseFailed(error.localizedDescription)
        }

        let credits = creditsData.flatMap { data -> HelmcodeCreditsResponse? in
            do {
                return try decoder.decode(HelmcodeCreditsResponse.self, from: data)
            } catch {
                self.log.info("Could not parse optional Helmcode credit balance: \(error.localizedDescription)")
                return nil
            }
        }
        return HelmcodeUsageSnapshot(quota: quota, credits: credits, updatedAt: now)
    }
}
