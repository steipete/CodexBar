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

// MARK: - Platform account summary / identity payloads

struct DeepSeekUserSummaryPayload: Decodable {
    let code: Int?
    let data: BizWrapper?

    struct BizWrapper: Decodable {
        let bizCode: Int?
        let bizData: BizData?
        enum CodingKeys: String, CodingKey {
            case bizCode = "biz_code"
            case bizData = "biz_data"
        }
    }

    struct BizData: Decodable {
        let normalWallets: [Wallet]?
        let bonusWallets: [Wallet]?
        let totalAvailableTokenEstimation: String?
        let monthlyCosts: [MoneyAmount]?
        let monthlyTokenUsage: String?
        enum CodingKeys: String, CodingKey {
            case normalWallets = "normal_wallets"
            case bonusWallets = "bonus_wallets"
            case totalAvailableTokenEstimation = "total_available_token_estimation"
            case monthlyCosts = "monthly_costs"
            case monthlyTokenUsage = "monthly_token_usage"
        }
    }

    struct Wallet: Decodable {
        let currency: String?
        let balance: String?
        let tokenEstimation: String?
        enum CodingKeys: String, CodingKey {
            case currency
            case balance
            case tokenEstimation = "token_estimation"
        }
    }

    struct MoneyAmount: Decodable {
        let currency: String?
        let amount: String?
    }

    enum CodingKeys: String, CodingKey {
        case code
        case data
    }
}

struct DeepSeekUserCurrentPayload: Decodable {
    let code: Int?
    let data: BizWrapper?

    struct BizWrapper: Decodable {
        let bizCode: Int?
        let bizData: BizData?
        enum CodingKeys: String, CodingKey {
            case bizCode = "biz_code"
            case bizData = "biz_data"
        }
    }

    struct BizData: Decodable {
        let email: String?
        let mobileNumber: String?
        let currency: String?
        let balanceAlert: [String: Alert]?
        enum CodingKeys: String, CodingKey {
            case email
            case currency
            case mobileNumber = "mobile_number"
            case balanceAlert = "balance_alert"
        }
    }

    struct Alert: Decodable {
        let enabled: Bool?
        let alertBound: String?
        enum CodingKeys: String, CodingKey {
            case enabled
            case alertBound = "alert_bound"
        }
    }

    enum CodingKeys: String, CodingKey {
        case code
        case data
    }
}

// MARK: - Account summary + identity (platform web session)

/// Wallet balances and token estimate from `/api/v0/users/get_user_summary`.
/// Available with a platform web session alone (no API key required).
public struct DeepSeekAccountSummary: Sendable, Equatable {
    public let currency: String
    public let paidBalance: Double
    public let grantedBalance: Double
    public let availableTokenEstimation: Int?
    public let monthlyCost: Double?
    public let monthlyTokenUsage: Int?
    public let updatedAt: Date

    public var totalBalance: Double {
        self.paidBalance + self.grantedBalance
    }

    public init(
        currency: String,
        paidBalance: Double,
        grantedBalance: Double,
        availableTokenEstimation: Int?,
        monthlyCost: Double?,
        monthlyTokenUsage: Int?,
        updatedAt: Date)
    {
        self.currency = currency
        self.paidBalance = paidBalance
        self.grantedBalance = grantedBalance
        self.availableTokenEstimation = availableTokenEstimation
        self.monthlyCost = monthlyCost
        self.monthlyTokenUsage = monthlyTokenUsage
        self.updatedAt = updatedAt
    }
}

/// Masked identity + balance-alert configuration from `/auth-api/v0/users/current`.
public struct DeepSeekAccountIdentity: Sendable, Equatable {
    public let email: String?
    public let maskedMobile: String?
    public let currency: String?
    public let balanceAlertEnabled: Bool
    public let balanceAlertBound: Double?

    public init(
        email: String?,
        maskedMobile: String?,
        currency: String?,
        balanceAlertEnabled: Bool,
        balanceAlertBound: Double?)
    {
        self.email = email
        self.maskedMobile = maskedMobile
        self.currency = currency
        self.balanceAlertEnabled = balanceAlertEnabled
        self.balanceAlertBound = balanceAlertBound
    }
}

// MARK: - Domain snapshot

public struct DeepSeekUsageSnapshot: Sendable {
    public let isAvailable: Bool
    public let currency: String
    public let totalBalance: Double
    public let grantedBalance: Double
    public let toppedUpBalance: Double
    public let usageSummary: DeepSeekUsageSummary?
    public let accountSummary: DeepSeekAccountSummary?
    public let identity: DeepSeekAccountIdentity?
    public let updatedAt: Date

    public init(
        isAvailable: Bool,
        currency: String,
        totalBalance: Double,
        grantedBalance: Double,
        toppedUpBalance: Double,
        usageSummary: DeepSeekUsageSummary? = nil,
        accountSummary: DeepSeekAccountSummary? = nil,
        identity: DeepSeekAccountIdentity? = nil,
        updatedAt: Date)
    {
        self.isAvailable = isAvailable
        self.currency = currency
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = toppedUpBalance
        self.usageSummary = usageSummary
        self.accountSummary = accountSummary
        self.identity = identity
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        // Prefer the web-session wallet balances when available; they cover the
        // no-API-key path and stay currency-consistent with the platform UI.
        let displayCurrency = self.accountSummary?.currency ?? self.currency
        let displayTotal = self.accountSummary?.totalBalance ?? self.totalBalance
        let displayPaid = self.accountSummary?.paidBalance ?? self.toppedUpBalance
        let displayGranted = self.accountSummary?.grantedBalance ?? self.grantedBalance
        let symbol = displayCurrency == "CNY" ? "¥" : "$"

        let balanceDetail: String
        let usedPercent: Double
        if displayTotal <= 0 {
            balanceDetail = "\(symbol)0.00 — add credits at platform.deepseek.com"
            usedPercent = 100
        } else if !self.isAvailable {
            balanceDetail = "Balance unavailable for API calls"
            usedPercent = 100
        } else {
            let total = String(format: "\(symbol)%.2f", displayTotal)
            let paid = String(format: "\(symbol)%.2f", displayPaid)
            let granted = String(format: "\(symbol)%.2f", displayGranted)
            var detail = "\(total) (Paid: \(paid) / Granted: \(granted))"
            // Surface the platform's own balance-alert threshold when the user
            // has enabled it and the balance has dropped below the bound.
            if let identity = self.identity,
               identity.balanceAlertEnabled,
               let bound = identity.balanceAlertBound,
               displayTotal < bound
            {
                detail += " — below alert \(symbol)\(String(format: "%.2f", bound))"
                balanceDetail = detail
                let providerIdentity = ProviderIdentitySnapshot(
                    providerID: .deepseek,
                    accountEmail: self.identity?.email,
                    accountOrganization: nil,
                    loginMethod: nil)
                let balanceWindow = RateWindow(
                    usedPercent: 0,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: balanceDetail)
                return UsageSnapshot(
                    primary: balanceWindow,
                    secondary: nil,
                    tertiary: nil,
                    providerCost: nil,
                    deepseekUsage: self.usageSummary,
                    updatedAt: self.updatedAt,
                    identity: providerIdentity)
            }
            balanceDetail = detail
            usedPercent = 0
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .deepseek,
            accountEmail: self.identity?.email,
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
            deepseekUsage: self.usageSummary,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

// MARK: - Errors

public enum DeepSeekUsageError: LocalizedError, Sendable {
    case missingCredentials
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing DeepSeek API key."
        case .invalidCredentials:
            "DeepSeek platform web session expired or invalid."
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
    private static let usageAmountURL = URL(string: "https://platform.deepseek.com/api/v0/usage/amount")!
    private static let usageCostURL = URL(string: "https://platform.deepseek.com/api/v0/usage/cost")!
    private static let userSummaryURL =
        URL(string: "https://platform.deepseek.com/api/v0/users/get_user_summary")!
    private static let userCurrentURL =
        URL(string: "https://platform.deepseek.com/auth-api/v0/users/current")!
    private static let timeoutSeconds: TimeInterval = 15
    private static let optionalSummaryJoinGrace: Duration = .seconds(2)
    private static var apiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    public static func fetchUsage(
        apiKey: String,
        includeOptionalUsage: Bool = true,
        platformSession: DeepSeekPlatformSession? = nil) async throws -> DeepSeekUsageSnapshot
    {
        try await self.fetchUsage(
            apiKey: apiKey,
            includeOptionalUsage: includeOptionalUsage,
            platformSession: platformSession,
            optionalSummaryJoinGrace: self.optionalSummaryJoinGrace,
            hooks: DeepSeekUsageFetchHooks(
                fetchBalanceData: { key in
                    try await self.fetchBalanceData(apiKey: key)
                },
                fetchSummary: { session in
                    try await self.fetchUsageSummary(session: session)
                }))
    }

    static func _fetchUsageForTesting(
        apiKey: String,
        includeOptionalUsage: Bool,
        platformSession: DeepSeekPlatformSession? = nil,
        optionalSummaryJoinGrace: Duration = .zero,
        fetchBalanceData: @escaping @Sendable (String) async throws -> Data,
        fetchSummary: @escaping @Sendable (DeepSeekPlatformSession) async throws -> DeepSeekUsageSummary)
        async throws -> DeepSeekUsageSnapshot
    {
        try await self.fetchUsage(
            apiKey: apiKey,
            includeOptionalUsage: includeOptionalUsage,
            platformSession: platformSession,
            optionalSummaryJoinGrace: optionalSummaryJoinGrace,
            hooks: DeepSeekUsageFetchHooks(
                fetchBalanceData: fetchBalanceData,
                fetchSummary: fetchSummary))
    }

    private struct DeepSeekUsageFetchHooks {
        let fetchBalanceData: @Sendable (String) async throws -> Data
        let fetchSummary: @Sendable (DeepSeekPlatformSession) async throws -> DeepSeekUsageSummary
    }

    private static func fetchUsage(
        apiKey: String,
        includeOptionalUsage: Bool,
        platformSession: DeepSeekPlatformSession?,
        optionalSummaryJoinGrace: Duration,
        hooks: DeepSeekUsageFetchHooks)
        async throws -> DeepSeekUsageSnapshot
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepSeekUsageError.missingCredentials
        }

        let summaryTask: Task<DeepSeekUsageSummary, Error>? = if includeOptionalUsage, let platformSession,
                                                                 !platformSession.isEmpty
        {
            Task {
                try await hooks.fetchSummary(platformSession)
            }
        } else {
            nil
        }

        let balanceData: Data
        do {
            balanceData = try await withTaskCancellationHandler {
                try await hooks.fetchBalanceData(apiKey)
            } onCancel: {
                summaryTask?.cancel()
            }
        } catch {
            summaryTask?.cancel()
            throw error
        }
        var snapshot: DeepSeekUsageSnapshot
        do {
            snapshot = try Self.parseSnapshot(data: balanceData)
        } catch {
            summaryTask?.cancel()
            throw error
        }

        if let summaryTask {
            let summary = try await self.completedOptionalUsageSummary(
                from: summaryTask,
                joinGrace: optionalSummaryJoinGrace)
            if let summary {
                snapshot = DeepSeekUsageSnapshot(
                    isAvailable: snapshot.isAvailable,
                    currency: snapshot.currency,
                    totalBalance: snapshot.totalBalance,
                    grantedBalance: snapshot.grantedBalance,
                    toppedUpBalance: snapshot.toppedUpBalance,
                    usageSummary: summary,
                    updatedAt: snapshot.updatedAt)
            }
        }

        return snapshot
    }

    private static func fetchBalanceData(apiKey: String) async throws -> Data {
        var request = URLRequest(url: self.balanceURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await ProviderHTTPClient.shared.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            Self.log.error("DeepSeek balance endpoint returned HTTP \(response.statusCode)")
            throw DeepSeekUsageError.apiError("HTTP \(response.statusCode)")
        }

        return data
    }

    private static func completedOptionalUsageSummary(
        from task: Task<DeepSeekUsageSummary, Error>,
        joinGrace: Duration) async throws -> DeepSeekUsageSummary?
    {
        let race = BoundedTaskJoin(sourceTask: task)
        switch await race.value(joinGrace: joinGrace) {
        case let .value(summary):
            try Task.checkCancellation()
            return summary
        case .timedOut:
            try Task.checkCancellation()
            return nil
        case let .failure(error):
            task.cancel()
            if Task.isCancelled {
                throw error
            }
            return nil
        }
    }

    static func _parseSnapshotForTesting(_ data: Data) throws -> DeepSeekUsageSnapshot {
        try self.parseSnapshot(data: data)
    }

    public static func fetchUsageSummary(
        session: DeepSeekPlatformSession,
        now: Date = Date(),
        calendar: Calendar? = nil) async throws -> DeepSeekUsageSummary
    {
        guard !session.isEmpty else {
            throw DeepSeekUsageError.invalidCredentials
        }
        let calendar = calendar ?? self.apiCalendar
        let period = try self.usagePeriod(now: now, calendar: calendar)

        let amountData = try await self.fetchAmount(
            session: session,
            month: period.month,
            year: period.year)
        let costData = try await self.fetchCost(
            session: session,
            month: period.month,
            year: period.year)

        var priorAmountData: Data?
        var priorCostData: Data?
        if self.needsPriorMonthData(now: now, calendar: calendar) {
            let prior = self.priorUsagePeriod(month: period.month, year: period.year, calendar: calendar)
            priorAmountData = try? await self.fetchAmount(session: session, month: prior.month, year: prior.year)
            priorCostData = try? await self.fetchCost(session: session, month: prior.month, year: prior.year)
        }

        return try DeepSeekUsageCostParser.parse(
            amountData: amountData,
            costData: costData,
            priorAmountData: priorAmountData,
            priorCostData: priorCostData,
            now: now,
            calendar: calendar)
    }

    static func _needsPriorMonthDataForTesting(now: Date, calendar: Calendar? = nil) -> Bool {
        self.needsPriorMonthData(now: now, calendar: calendar ?? self.apiCalendar)
    }

    static func _priorUsagePeriodForTesting(
        month: Int,
        year: Int,
        calendar: Calendar? = nil) -> (month: Int, year: Int)
    {
        self.priorUsagePeriod(month: month, year: year, calendar: calendar ?? self.apiCalendar)
    }

    private static func needsPriorMonthData(now: Date, calendar: Calendar) -> Bool {
        var components = calendar.dateComponents([.year, .month], from: now)
        components.day = 1
        guard let startOfMonth = calendar.date(from: components) else { return false }
        let rollingStart = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? startOfMonth
        return rollingStart < startOfMonth
    }

    private static func priorUsagePeriod(
        month: Int,
        year: Int,
        calendar: Calendar) -> (month: Int, year: Int)
    {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        guard let date = calendar.date(from: components),
              let prior = calendar.date(byAdding: .month, value: -1, to: date)
        else {
            return (month: month, year: year)
        }
        let priorComponents = calendar.dateComponents([.month, .year], from: prior)
        return (month: priorComponents.month ?? month, year: priorComponents.year ?? year)
    }

    static func _apiUsagePeriodForTesting(now: Date, calendar: Calendar? = nil) throws -> (month: Int, year: Int) {
        try self.usagePeriod(now: now, calendar: calendar ?? self.apiCalendar)
    }

    private static func usagePeriod(now: Date, calendar: Calendar) throws -> (month: Int, year: Int) {
        let monthComponents = calendar.dateComponents([.month, .year], from: now)
        guard let month = monthComponents.month, let year = monthComponents.year else {
            throw DeepSeekUsageError.parseFailed("Could not determine current month/year")
        }
        return (month: month, year: year)
    }

    private static func fetchAmount(session: DeepSeekPlatformSession, month: Int, year: Int) async throws -> Data {
        try await self.fetchPlatformData(
            url: self.usageAmountURL,
            session: session,
            month: month,
            year: year)
    }

    private static func fetchCost(session: DeepSeekPlatformSession, month: Int, year: Int) async throws -> Data {
        try await self.fetchPlatformData(
            url: self.usageCostURL,
            session: session,
            month: month,
            year: year)
    }

    private static func makePlatformRequest(url: URL, session: DeepSeekPlatformSession) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://platform.deepseek.com", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.deepseek.com/usage", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        if let cookieHeader = session.cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let authorizationHeader = session.authorizationHeader, !authorizationHeader.isEmpty {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = Self.timeoutSeconds
        return request
    }

    private static func performPlatformRequest(_ request: URLRequest) async throws -> Data {
        let response = try await ProviderHTTPClient.shared.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw DeepSeekUsageError.invalidCredentials
            }
            throw DeepSeekUsageError.apiError("HTTP \(response.statusCode)")
        }
        if DeepSeekCookieHeader.isAuthFailurePayload(data) {
            throw DeepSeekUsageError.invalidCredentials
        }
        return data
    }

    private static func fetchPlatformData(
        url: URL,
        session: DeepSeekPlatformSession,
        month: Int,
        year: Int) async throws -> Data
    {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DeepSeekUsageError.networkError("Invalid URL")
        }
        components.queryItems = [
            URLQueryItem(name: "month", value: String(month)),
            URLQueryItem(name: "year", value: String(year)),
        ]
        guard let requestURL = components.url else {
            throw DeepSeekUsageError.networkError("Could not construct URL")
        }

        let request = self.makePlatformRequest(url: requestURL, session: session)
        return try await self.performPlatformRequest(request)
    }

    // MARK: - Account summary + identity

    public static func fetchWebAccount(
        session: DeepSeekPlatformSession) async throws
        -> (summary: DeepSeekAccountSummary?, identity: DeepSeekAccountIdentity?)
    {
        guard !session.isEmpty else {
            throw DeepSeekUsageError.invalidCredentials
        }
        let summary = try await self.fetchAccountSummary(session: session)
        let identity = try? await self.fetchIdentity(session: session)
        return (summary, identity)
    }

    public static func fetchAccountSummary(
        session: DeepSeekPlatformSession) async throws -> DeepSeekAccountSummary
    {
        guard !session.isEmpty else { throw DeepSeekUsageError.invalidCredentials }
        let request = self.makePlatformRequest(url: self.userSummaryURL, session: session)
        let data = try await self.performPlatformRequest(request)
        return try self.parseAccountSummary(data: data)
    }

    public static func fetchIdentity(
        session: DeepSeekPlatformSession) async throws -> DeepSeekAccountIdentity
    {
        guard !session.isEmpty else { throw DeepSeekUsageError.invalidCredentials }
        let request = self.makePlatformRequest(url: self.userCurrentURL, session: session)
        let data = try await self.performPlatformRequest(request)
        return try self.parseIdentity(data: data)
    }

    static func _parseAccountSummaryForTesting(_ data: Data) throws -> DeepSeekAccountSummary {
        try self.parseAccountSummary(data: data)
    }

    static func _fetchAccountSummaryDataForTesting(session: DeepSeekPlatformSession) async throws -> Data {
        let request = self.makePlatformRequest(url: self.userSummaryURL, session: session)
        return try await self.performPlatformRequest(request)
    }

    static func _parseIdentityForTesting(_ data: Data) throws -> DeepSeekAccountIdentity {
        try self.parseIdentity(data: data)
    }

    private static func parseAccountSummary(data: Data) throws -> DeepSeekAccountSummary {
        let payload: DeepSeekUserSummaryPayload
        do {
            payload = try JSONDecoder().decode(DeepSeekUserSummaryPayload.self, from: data)
        } catch {
            throw DeepSeekUsageError.parseFailed(error.localizedDescription)
        }
        if let code = payload.code, code == 40002 || code == 40003 {
            throw DeepSeekUsageError.invalidCredentials
        }
        if let code = payload.code, code != 0 {
            throw DeepSeekUsageError.apiError("summary code \(code)")
        }
        if let bizCode = payload.data?.bizCode, bizCode != 0 {
            throw DeepSeekUsageError.apiError("summary biz_code \(bizCode)")
        }
        guard let biz = payload.data?.bizData else {
            throw DeepSeekUsageError.parseFailed("Missing user summary biz_data")
        }
        let normal = biz.normalWallets ?? []
        let bonus = biz.bonusWallets ?? []
        guard !normal.isEmpty || !bonus.isEmpty else {
            throw DeepSeekUsageError.parseFailed("Missing wallets")
        }

        let currency = Self.preferredWalletCurrency(normal: normal, bonus: bonus)
        let paid = Self.walletBalance(normal, currency: currency)
        let granted = Self.walletBalance(bonus, currency: currency)
        let availableToken = Self.parseIntString(biz.totalAvailableTokenEstimation)
        let monthlyCost = biz.monthlyCosts?
            .first { ($0.currency ?? currency) == currency }
            .flatMap { Double($0.amount ?? "") }

        return DeepSeekAccountSummary(
            currency: currency,
            paidBalance: paid,
            grantedBalance: granted,
            availableTokenEstimation: availableToken,
            monthlyCost: monthlyCost,
            monthlyTokenUsage: Self.parseIntString(biz.monthlyTokenUsage),
            updatedAt: Date())
    }

    private static func parseIdentity(data: Data) throws -> DeepSeekAccountIdentity {
        let payload: DeepSeekUserCurrentPayload
        do {
            payload = try JSONDecoder().decode(DeepSeekUserCurrentPayload.self, from: data)
        } catch {
            throw DeepSeekUsageError.parseFailed(error.localizedDescription)
        }
        if let code = payload.code, code == 40002 || code == 40003 {
            throw DeepSeekUsageError.invalidCredentials
        }
        if let code = payload.code, code != 0 {
            throw DeepSeekUsageError.apiError("identity code \(code)")
        }
        if let bizCode = payload.data?.bizCode, bizCode != 0 {
            throw DeepSeekUsageError.apiError("identity biz_code \(bizCode)")
        }
        guard let biz = payload.data?.bizData else {
            throw DeepSeekUsageError.parseFailed("Missing identity biz_data")
        }
        let currency = biz.currency ?? "CNY"
        let alert = biz.balanceAlert?[currency]
        let enabled = alert?.enabled ?? false
        let bound = alert?.alertBound.flatMap { Double($0) }
        return DeepSeekAccountIdentity(
            email: biz.email,
            maskedMobile: biz.mobileNumber,
            currency: biz.currency,
            balanceAlertEnabled: enabled,
            balanceAlertBound: bound)
    }

    private static func preferredWalletCurrency(
        normal: [DeepSeekUserSummaryPayload.Wallet],
        bonus: [DeepSeekUserSummaryPayload.Wallet]) -> String
    {
        let wallets = normal + bonus
        if wallets.contains(where: { $0.currency == "USD" && (Double($0.balance ?? "") ?? 0) > 0 }) {
            return "USD"
        }
        if let funded = wallets.first(where: { (Double($0.balance ?? "") ?? 0) > 0 }) {
            return funded.currency ?? "CNY"
        }
        return normal.first?.currency ?? bonus.first?.currency ?? "CNY"
    }

    private static func walletBalance(
        _ wallets: [DeepSeekUserSummaryPayload.Wallet],
        currency: String) -> Double
    {
        wallets
            .filter { ($0.currency ?? currency) == currency }
            .reduce(0) { $0 + (Double($1.balance ?? "") ?? 0) }
    }

    private static func parseIntString(_ value: String?) -> Int? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int64(trimmed) else { return nil }
        return Int(parsed)
    }

    static func _parseUsageSummaryForTesting(
        amountData: Data,
        costData: Data,
        priorAmountData: Data? = nil,
        priorCostData: Data? = nil,
        now: Date = Date(),
        calendar: Calendar = .current) throws -> DeepSeekUsageSummary
    {
        try DeepSeekUsageCostParser.parse(
            amountData: amountData,
            costData: costData,
            priorAmountData: priorAmountData,
            priorCostData: priorCostData,
            now: now,
            calendar: calendar)
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
