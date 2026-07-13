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

public enum DeepSeekDetailedUsageState: Sendable, Equatable {
    case notRequested
    case available
    case webSessionRequired
    case profileSelectionRequired
    case unavailable
}

public struct DeepSeekPlatformProfile: Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct DeepSeekUsageSnapshot: Sendable {
    public let isAvailable: Bool
    public let currency: String
    public let totalBalance: Double
    public let grantedBalance: Double
    public let toppedUpBalance: Double
    public let usageSummary: DeepSeekUsageSummary?
    public let detailedUsageState: DeepSeekDetailedUsageState
    public let platformProfiles: [DeepSeekPlatformProfile]
    public let updatedAt: Date

    public init(
        isAvailable: Bool,
        currency: String,
        totalBalance: Double,
        grantedBalance: Double,
        toppedUpBalance: Double,
        usageSummary: DeepSeekUsageSummary? = nil,
        detailedUsageState: DeepSeekDetailedUsageState? = nil,
        platformProfiles: [DeepSeekPlatformProfile] = [],
        updatedAt: Date)
    {
        self.isAvailable = isAvailable
        self.currency = currency
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = toppedUpBalance
        self.usageSummary = usageSummary
        self.detailedUsageState = detailedUsageState ?? (usageSummary == nil ? .notRequested : .available)
        self.platformProfiles = platformProfiles
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
            deepseekUsage: self.usageSummary,
            deepseekDetailedUsageState: self.detailedUsageState,
            deepseekPlatformProfiles: self.platformProfiles,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

// MARK: - Errors

public enum DeepSeekUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidPlatformToken
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing DeepSeek API key."
        case .invalidPlatformToken:
            "DeepSeek Platform session is missing or expired."
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
    private enum UsageSummaryPayload: Sendable {
        case amount(Data)
        case cost(Data)
    }

    private static let log = CodexBarLog.logger(LogCategories.deepSeekUsage)
    private static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    private static let usageAmountURL = URL(string: "https://platform.deepseek.com/api/v0/usage/amount")!
    private static let usageCostURL = URL(string: "https://platform.deepseek.com/api/v0/usage/cost")!
    private static let timeoutSeconds: TimeInterval = 15
    private static let optionalSummaryJoinGrace: Duration = .seconds(5)
    private static var apiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    public static func fetchUsage(
        apiKey: String,
        platformToken: String? = nil,
        includeOptionalUsage: Bool = true) async throws -> DeepSeekUsageSnapshot
    {
        try await self.fetchUsage(
            apiKey: apiKey,
            platformToken: platformToken,
            includeOptionalUsage: includeOptionalUsage,
            optionalSummaryJoinGrace: self.optionalSummaryJoinGrace,
            operations: FetchOperations(
                fetchBalanceData: { key in
                    try await self.fetchBalanceData(apiKey: key)
                },
                fetchSummary: { token in
                    try await self.fetchUsageSummary(platformToken: token)
                }))
    }

    static func _fetchUsageForTesting(
        apiKey: String,
        platformToken: String? = nil,
        includeOptionalUsage: Bool,
        optionalSummaryJoinGrace: Duration = .zero,
        fetchBalanceData: @escaping @Sendable (String) async throws -> Data,
        fetchSummary: @escaping @Sendable (String) async throws -> DeepSeekUsageSummary)
        async throws -> DeepSeekUsageSnapshot
    {
        try await self.fetchUsage(
            apiKey: apiKey,
            platformToken: platformToken,
            includeOptionalUsage: includeOptionalUsage,
            optionalSummaryJoinGrace: optionalSummaryJoinGrace,
            operations: FetchOperations(
                fetchBalanceData: fetchBalanceData,
                fetchSummary: fetchSummary))
    }

    private struct FetchOperations: Sendable {
        let fetchBalanceData: @Sendable (String) async throws -> Data
        let fetchSummary: @Sendable (String) async throws -> DeepSeekUsageSummary
    }

    private static func fetchUsage(
        apiKey: String,
        platformToken: String?,
        includeOptionalUsage: Bool,
        optionalSummaryJoinGrace: Duration,
        operations: FetchOperations)
        async throws -> DeepSeekUsageSnapshot
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepSeekUsageError.missingCredentials
        }

        let normalizedPlatformToken = platformToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usablePlatformToken = normalizedPlatformToken?.isEmpty == false ? normalizedPlatformToken : nil
        let summaryTask: Task<DeepSeekUsageSummary, Error>? = if includeOptionalUsage, let usablePlatformToken {
            Task {
                try await operations.fetchSummary(usablePlatformToken)
            }
        } else {
            nil
        }

        let balanceData: Data
        do {
            balanceData = try await withTaskCancellationHandler {
                try await operations.fetchBalanceData(apiKey)
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

        let initialDetailedUsageState: DeepSeekDetailedUsageState = if !includeOptionalUsage {
            .notRequested
        } else if usablePlatformToken == nil {
            .webSessionRequired
        } else {
            .unavailable
        }
        snapshot = DeepSeekUsageSnapshot(
            isAvailable: snapshot.isAvailable,
            currency: snapshot.currency,
            totalBalance: snapshot.totalBalance,
            grantedBalance: snapshot.grantedBalance,
            toppedUpBalance: snapshot.toppedUpBalance,
            usageSummary: nil,
            detailedUsageState: initialDetailedUsageState,
            platformProfiles: snapshot.platformProfiles,
            updatedAt: snapshot.updatedAt)

        if let summaryTask {
            let completion = try await self.completedOptionalUsageSummary(
                from: summaryTask,
                joinGrace: optionalSummaryJoinGrace)
            snapshot = DeepSeekUsageSnapshot(
                isAvailable: snapshot.isAvailable,
                currency: snapshot.currency,
                totalBalance: snapshot.totalBalance,
                grantedBalance: snapshot.grantedBalance,
                toppedUpBalance: snapshot.toppedUpBalance,
                usageSummary: completion.summary,
                detailedUsageState: completion.state,
                platformProfiles: snapshot.platformProfiles,
                updatedAt: snapshot.updatedAt)
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
        joinGrace: Duration) async throws
        -> (summary: DeepSeekUsageSummary?, state: DeepSeekDetailedUsageState)
    {
        let race = BoundedTaskJoin(sourceTask: task)
        switch await race.value(joinGrace: joinGrace) {
        case let .value(summary):
            try Task.checkCancellation()
            return (summary, .available)
        case .timedOut:
            try Task.checkCancellation()
            Self.log.warning("DeepSeek detailed usage unavailable", metadata: ["reason": "timeout"])
            return (nil, .unavailable)
        case let .failure(error):
            task.cancel()
            if Task.isCancelled {
                throw error
            }
            Self.log.warning(
                "DeepSeek detailed usage unavailable",
                metadata: ["reason": self.optionalSummaryFailureReason(error)])
            return (nil, error is DeepSeekUsageError ? self.optionalSummaryFailureState(error) : .unavailable)
        }
    }

    private static func optionalSummaryFailureState(_ error: any Error) -> DeepSeekDetailedUsageState {
        guard let error = error as? DeepSeekUsageError else { return .unavailable }
        return error == .invalidPlatformToken ? .webSessionRequired : .unavailable
    }

    private static func optionalSummaryFailureReason(_ error: any Error) -> String {
        guard let error = error as? DeepSeekUsageError else {
            return error is CancellationError ? "cancelled" : "unknown"
        }

        switch error {
        case .missingCredentials: return "missing_credentials"
        case .invalidPlatformToken: return "platform_auth"
        case .networkError: return "network"
        case .apiError: return "api"
        case .parseFailed: return "parse"
        }
    }

    static func _parseSnapshotForTesting(_ data: Data) throws -> DeepSeekUsageSnapshot {
        try self.parseSnapshot(data: data)
    }

    public static func fetchUsageSummary(
        platformToken: String,
        now: Date = Date(),
        calendar: Calendar? = nil) async throws -> DeepSeekUsageSummary
    {
        let calendar = calendar ?? self.apiCalendar
        let period = try self.usagePeriod(now: now, calendar: calendar)
        let payloads = try await self.fetchUsagePayloads(
            fetchAmount: {
                try await self.fetchAmount(platformToken: platformToken, month: period.month, year: period.year)
            },
            fetchCost: {
                try await self.fetchCost(platformToken: platformToken, month: period.month, year: period.year)
            })

        return try DeepSeekUsageCostParser.parse(
            amountData: payloads.amount,
            costData: payloads.cost,
            now: now,
            calendar: calendar)
    }

    static func _fetchUsagePayloadsForTesting(
        fetchAmount: @escaping @Sendable () async throws -> Data,
        fetchCost: @escaping @Sendable () async throws -> Data) async throws -> (amount: Data, cost: Data)
    {
        try await self.fetchUsagePayloads(fetchAmount: fetchAmount, fetchCost: fetchCost)
    }

    private static func fetchUsagePayloads(
        fetchAmount: @escaping @Sendable () async throws -> Data,
        fetchCost: @escaping @Sendable () async throws -> Data) async throws -> (amount: Data, cost: Data)
    {
        try await withThrowingTaskGroup(of: UsageSummaryPayload.self) { group in
            group.addTask {
                try await .amount(fetchAmount())
            }
            group.addTask {
                try await .cost(fetchCost())
            }

            var amountData: Data?
            var costData: Data?
            for try await payload in group {
                switch payload {
                case let .amount(data): amountData = data
                case let .cost(data): costData = data
                }
            }

            guard let amountData, let costData else {
                throw DeepSeekUsageError.parseFailed("Missing usage response")
            }
            return (amount: amountData, cost: costData)
        }
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

    private static func fetchAmount(platformToken: String, month: Int, year: Int) async throws -> Data {
        guard var components = URLComponents(url: self.usageAmountURL, resolvingAgainstBaseURL: false) else {
            throw DeepSeekUsageError.networkError("Invalid URL")
        }
        components.queryItems = [
            URLQueryItem(name: "month", value: String(month)),
            URLQueryItem(name: "year", value: String(year)),
        ]
        guard let url = components.url else {
            throw DeepSeekUsageError.networkError("Could not construct URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(platformToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await ProviderHTTPClient.shared.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw DeepSeekUsageError.invalidPlatformToken
            }
            throw DeepSeekUsageError.apiError("HTTP \(response.statusCode)")
        }

        return data
    }

    private static func fetchCost(platformToken: String, month: Int, year: Int) async throws -> Data {
        guard var components = URLComponents(url: self.usageCostURL, resolvingAgainstBaseURL: false) else {
            throw DeepSeekUsageError.networkError("Invalid URL")
        }
        components.queryItems = [
            URLQueryItem(name: "month", value: String(month)),
            URLQueryItem(name: "year", value: String(year)),
        ]
        guard let url = components.url else {
            throw DeepSeekUsageError.networkError("Could not construct URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(platformToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await ProviderHTTPClient.shared.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw DeepSeekUsageError.invalidPlatformToken
            }
            throw DeepSeekUsageError.apiError("HTTP \(response.statusCode)")
        }

        return data
    }

    static func _parseUsageSummaryForTesting(
        amountData: Data,
        costData: Data,
        now: Date = Date(),
        calendar: Calendar = .current) throws -> DeepSeekUsageSummary
    {
        try DeepSeekUsageCostParser.parse(
            amountData: amountData,
            costData: costData,
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
