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
    public let remaining: Int64?
    public let periodEnd: String?
    public let updatedAt: String?
    public let windowHours: Int?
    public let fullWindowTokens: Int64?

    public init(
        model: String,
        cap: Int64,
        tokensUsed: Int64,
        creditTokens: Int64? = nil,
        creditSpendMicros: Int64? = nil,
        remaining: Int64? = nil,
        periodEnd: String? = nil,
        updatedAt: String? = nil,
        windowHours: Int? = nil,
        fullWindowTokens: Int64? = nil)
    {
        self.model = model
        self.cap = cap
        self.tokensUsed = tokensUsed
        self.creditTokens = creditTokens
        self.creditSpendMicros = creditSpendMicros
        self.remaining = remaining
        self.periodEnd = periodEnd
        self.updatedAt = updatedAt
        self.windowHours = windowHours
        self.fullWindowTokens = fullWindowTokens
    }
}

public struct HelmcodeQuotaResponse: Decodable, Equatable, Sendable {
    public let periodStart: String
    public let models: [HelmcodeModelQuota]
}

public struct HelmcodeSubscription: Decodable, Equatable, Sendable {
    public let status: String?
    public let premium: Bool?
    public let currency: String?
    public let currentPeriodStart: Int64?
    public let currentPeriodEnd: Int64?
}

public struct HelmcodeBillingResponse: Decodable, Equatable, Sendable {
    public let subscription: HelmcodeSubscription?
}

public struct HelmcodeCreditsResponse: Decodable, Equatable, Sendable {
    public let balanceMicros: Int64
    public let currency: String

    public init(balanceMicros: Int64, currency: String? = nil) {
        self.balanceMicros = balanceMicros
        self.currency = currency ?? "EUR"
    }

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
    public let billing: HelmcodeBillingResponse?
    public let credits: HelmcodeCreditsResponse?
    public let updatedAt: Date

    public init(
        quota: HelmcodeQuotaResponse,
        billing: HelmcodeBillingResponse? = nil,
        credits: HelmcodeCreditsResponse?,
        updatedAt: Date)
    {
        self.quota = quota
        self.billing = billing
        self.credits = credits
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let metered = self.quota.models
            // Premium rolling-window tiers are "NOT IN YOUR PLAN" unless the subscription is premium.
                .filter { quota in
                    self.billing?.subscription?.premium == false ? quota.windowHours == nil : true
                }
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
                window: Self.rateWindow(
                    quota,
                    fallbackResetAt: Self.nextMonthStart(periodStart: self.quota.periodStart)))
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

    private static func rateWindow(_ quota: HelmcodeModelQuota, fallbackResetAt: Date?) -> RateWindow {
        let percent = min(100, max(0, Double(quota.tokensUsed) / Double(quota.cap) * 100))
        var detail = "\(quota.model) · \(Self.formatTokens(quota.tokensUsed)) / " +
            "\(Self.formatTokens(quota.cap)) tokens"
        if let creditTokens = quota.creditTokens, creditTokens > 0 {
            detail += " · \(Self.formatTokens(creditTokens)) credit-funded"
        }
        return RateWindow(
            usedPercent: percent,
            windowMinutes: quota.windowHours.map { $0 * 60 },
            resetsAt: quota.periodEnd.flatMap { Self.parseISODate($0) } ?? fallbackResetAt,
            resetDescription: detail)
    }

    static func parseISODate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)
    }

    private static func formatTokens(_ value: Int64) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    static func nextMonthStart(periodStart: String) -> Date? {
        let prefix = String(periodStart.prefix(10))
        let pieces = prefix.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3, (1...12).contains(pieces[1]), (1...31).contains(pieces[2]) else { return nil }
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
    case missingCookies(HelmcodeDeployment)
    case missingCookiesAny
    case invalidSession(HelmcodeDeployment)
    case rateLimited
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .missingCookies(deployment):
            "No \(deployment.displayName) dashboard session found. Sign in at \(deployment.dashboardHost) " +
                "or paste a Cookie header."
        case .missingCookiesAny:
            "No Helmcode dashboard session found. Sign in at cloud.helmcode.com or cloud.nan.builders, " +
                "or paste a Cookie header."
        case let .invalidSession(deployment):
            "\(deployment.displayName) dashboard session expired. Sign in again at \(deployment.dashboardHost)."
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
    /// Default enterprise deployment endpoints, kept for callers that do not select a tenant.
    public static let quotaURL = HelmcodeDeployment.helmcode.quotaURL
    public static let creditsURL = HelmcodeDeployment.helmcode.creditsURL
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

    /// Refuses every redirect: a 3xx surfaces to `get()` (mapped to invalidSession) instead of being
    /// followed with the Cookie header attached, so a path-scoped cookie can never reach an
    /// out-of-scope path across a redirect (G1).
    private static let defaultTransport: ProviderHTTPClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return ProviderHTTPClient(session: ProviderHTTPClient.redirectGuardedSession(
            configuration: configuration,
            refusesAllRedirects: true))
    }()

    public static func fetchUsage(
        cookieHeader: String,
        deployment: HelmcodeDeployment = .helmcode,
        transport transportOverride: (any ProviderHTTPTransport)? = nil,
        now: Date = Date(),
        verbose: (@Sendable (String) -> Void)? = nil) async throws -> HelmcodeUsageSnapshot
    {
        try await self.fetchUsage(
            authentication: .header(cookieHeader),
            deployment: deployment,
            transport: transportOverride ?? self.defaultTransport,
            now: now,
            verbose: verbose)
    }

    static func fetchUsage(
        cookies: [HTTPCookie],
        deployment: HelmcodeDeployment = .helmcode,
        transport transportOverride: (any ProviderHTTPTransport)? = nil,
        now: Date = Date(),
        verbose: (@Sendable (String) -> Void)? = nil) async throws -> HelmcodeUsageSnapshot
    {
        try await self.fetchUsage(
            authentication: .cookies(cookies),
            deployment: deployment,
            transport: transportOverride ?? self.defaultTransport,
            now: now,
            verbose: verbose)
    }

    static func _parseSnapshotForTesting(
        quotaData: Data,
        billingData: Data? = nil,
        creditsData: Data?,
        now: Date = Date()) throws -> HelmcodeUsageSnapshot
    {
        try self.parseSnapshot(
            quotaData: quotaData,
            billingData: billingData,
            creditsData: creditsData,
            now: now)
    }

    private static func fetchUsage(
        authentication: Authentication,
        deployment: HelmcodeDeployment,
        transport: any ProviderHTTPTransport,
        now: Date,
        verbose: (@Sendable (String) -> Void)? = nil) async throws -> HelmcodeUsageSnapshot
    {
        guard authentication.header(for: deployment.quotaURL) != nil else {
            throw HelmcodeUsageError.missingCookies(deployment)
        }

        let quotaData = try await self.get(
            deployment.quotaURL,
            deployment: deployment,
            authentication: authentication,
            transport: transport,
            verbose: verbose)
        var billingData: Data?
        do {
            billingData = try await self.get(
                deployment.billingURL,
                deployment: deployment,
                authentication: authentication,
                transport: transport,
                verbose: verbose)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.info("Helmcode billing unavailable (non-fatal): \(error.localizedDescription)")
        }
        var creditsData: Data?
        do {
            creditsData = try await self.get(
                deployment.creditsURL,
                deployment: deployment,
                authentication: authentication,
                transport: transport,
                verbose: verbose)
        } catch is CancellationError {
            throw CancellationError()
        } catch HelmcodeUsageError.apiError(404) {
            self.log.info("No prepaid balance for this tenant (credits endpoint unavailable).")
        } catch {
            self.log.info("Helmcode credit balance unavailable (non-fatal): \(error.localizedDescription)")
        }
        return try self.parseSnapshot(
            quotaData: quotaData,
            billingData: billingData,
            creditsData: creditsData,
            now: now)
    }

    private static func get(
        _ url: URL,
        deployment: HelmcodeDeployment,
        authentication: Authentication,
        transport: any ProviderHTTPTransport,
        verbose: (@Sendable (String) -> Void)? = nil) async throws -> Data
    {
        if let verbose {
            switch authentication {
            case let .cookies(cookies):
                let detail = HelmcodeCookieHeader.headerWithDiagnostics(
                    from: cookies,
                    for: url,
                    now: Date())
                verbose(
                    "GET \(url.host ?? "")\(url.path) cookies=[\(detail.included.joined(separator: ", "))] " +
                        "excluded-expired=[\(detail.expired.joined(separator: ", "))] " +
                        "excluded-path=[\(detail.pathExcluded.joined(separator: ", "))]")
            case .header:
                verbose("helmcode: GET \(url.host ?? "")\(url.path) credential=header")
            }
        }
        guard let cookieHeader = authentication.header(for: url) else {
            throw HelmcodeUsageError.missingCookies(deployment)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(deployment.dashboardURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(deployment.dashboardPageURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = self.timeoutSeconds

        let response = try await transport.response(for: request, retryPolicy: .transientIdempotent)
        if let verbose, 300...399 ~= response.statusCode {
            let location = response.response.value(forHTTPHeaderField: "Location")
            let target = location.flatMap { URL(string: $0) }
            verbose(
                "helmcode: redirect refused \(url.host ?? "")\(url.path) -> " +
                    "\(target.map { "\($0.host ?? "")\($0.path)" } ?? location ?? "?")")
        }
        switch response.statusCode {
        case 200:
            return response.data
        case 300...399, 401, 403:
            throw HelmcodeUsageError.invalidSession(deployment)
        case 429:
            throw HelmcodeUsageError.rateLimited
        default:
            throw HelmcodeUsageError.apiError(response.statusCode)
        }
    }

    private static func parseSnapshot(
        quotaData: Data,
        billingData: Data?,
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

        let billing = billingData.flatMap { data -> HelmcodeBillingResponse? in
            do {
                return try decoder.decode(HelmcodeBillingResponse.self, from: data)
            } catch {
                self.log.info("Could not parse optional Helmcode billing: \(error.localizedDescription)")
                return nil
            }
        }

        let credits = creditsData.flatMap { data -> HelmcodeCreditsResponse? in
            do {
                return try decoder.decode(HelmcodeCreditsResponse.self, from: data)
            } catch {
                self.log.info("Could not parse optional Helmcode credit balance: \(error.localizedDescription)")
                return nil
            }
        }
        return HelmcodeUsageSnapshot(
            quota: quota,
            billing: billing,
            credits: credits,
            updatedAt: now)
    }
}
