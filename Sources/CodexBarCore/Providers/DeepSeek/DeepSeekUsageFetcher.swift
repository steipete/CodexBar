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

private struct DeepSeekPlatformUserSummaryResponse: Decodable {
    let code: Int?
    let data: DeepSeekPlatformUserSummaryData?

    private enum CodingKeys: String, CodingKey {
        case code, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decodeIfPresent(Int.self, forKey: .code)
        if let code, code != 0 {
            // Error envelopes are not schema-stable. Preserve their code before inspecting `data`.
            self.data = try? container.decodeIfPresent(DeepSeekPlatformUserSummaryData.self, forKey: .data)
        } else {
            self.data = try container.decodeIfPresent(DeepSeekPlatformUserSummaryData.self, forKey: .data)
        }
    }
}

private struct DeepSeekPlatformUserSummaryData: Decodable {
    let bizCode: Int?
    let bizData: DeepSeekPlatformUserSummary?

    enum CodingKeys: String, CodingKey {
        case bizCode = "biz_code"
        case bizData = "biz_data"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bizCode = try container.decodeIfPresent(Int.self, forKey: .bizCode)
        if let bizCode, bizCode != 0 {
            self.bizData = try? container.decodeIfPresent(DeepSeekPlatformUserSummary.self, forKey: .bizData)
        } else {
            self.bizData = try container.decodeIfPresent(DeepSeekPlatformUserSummary.self, forKey: .bizData)
        }
    }
}

private struct DeepSeekPlatformUserSummary: Decodable {
    let normalWallets: [DeepSeekPlatformWallet]
    let bonusWallets: [DeepSeekPlatformWallet]

    enum CodingKeys: String, CodingKey {
        case normalWallets = "normal_wallets"
        case bonusWallets = "bonus_wallets"
    }
}

private struct DeepSeekPlatformWallet: Decodable {
    let balance: Double
    let currency: String

    enum CodingKeys: String, CodingKey {
        case balance, currency
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.currency = try container.decode(String.self, forKey: .currency)
        if let number = try? container.decode(Double.self, forKey: .balance) {
            self.balance = number
            return
        }
        let value = try container.decode(String.self, forKey: .balance)
        guard let number = Double(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: .balance,
                in: container,
                debugDescription: "Expected a numeric wallet balance")
        }
        self.balance = number
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

/// Non-secret metadata for an already-selected DeepSeek session eligible for wide history loading.
public struct DeepSeekHistorySessionMetadata: Sendable, Equatable {
    public let profileID: String?
    public let ownerTokenDigest: String?
    public let plan: DeepSeekHistoryPlan
    public let recentFold: DeepSeekChunkFoldResult

    public init(
        profileID: String?,
        ownerTokenDigest: String?,
        plan: DeepSeekHistoryPlan,
        recentFold: DeepSeekChunkFoldResult)
    {
        self.profileID = profileID
        self.ownerTokenDigest = ownerTokenDigest
        self.plan = plan
        self.recentFold = recentFold
    }
}

/// Live-only continuation bound to the already-selected DeepSeek session in process memory.
/// The raw platform token stays captured inside the closure and never enters snapshots or persistence.
public struct DeepSeekWideHistoryContinuation: Sendable {
    public let metadata: DeepSeekHistorySessionMetadata
    public let fetchChunk: @Sendable (DeepSeekUsageWindow) async throws -> DeepSeekChunkFoldResult

    public init(
        metadata: DeepSeekHistorySessionMetadata,
        fetchChunk: @escaping @Sendable (DeepSeekUsageWindow) async throws -> DeepSeekChunkFoldResult)
    {
        self.metadata = metadata
        self.fetchChunk = fetchChunk
    }
}

public struct DeepSeekUsageSnapshot: Sendable {
    public let hasBalance: Bool
    public let isAvailable: Bool
    public let currency: String
    public let totalBalance: Double
    public let grantedBalance: Double
    public let toppedUpBalance: Double
    public let usageSummary: DeepSeekUsageSummary?
    public let detailedUsageState: DeepSeekDetailedUsageState
    public let platformProfiles: [DeepSeekPlatformProfile]
    public let platformBalanceOwner: DeepSeekPlatformBalanceOwner?
    public let historyContinuation: DeepSeekWideHistoryContinuation?
    public let updatedAt: Date

    public init(
        hasBalance: Bool = true,
        isAvailable: Bool,
        currency: String,
        totalBalance: Double,
        grantedBalance: Double,
        toppedUpBalance: Double,
        usageSummary: DeepSeekUsageSummary? = nil,
        detailedUsageState: DeepSeekDetailedUsageState? = nil,
        platformProfiles: [DeepSeekPlatformProfile] = [],
        platformBalanceOwner: DeepSeekPlatformBalanceOwner? = nil,
        historyContinuation: DeepSeekWideHistoryContinuation? = nil,
        updatedAt: Date)
    {
        self.hasBalance = hasBalance
        self.isAvailable = isAvailable
        self.currency = currency
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = toppedUpBalance
        self.usageSummary = usageSummary
        self.detailedUsageState = detailedUsageState ?? (usageSummary == nil ? .notRequested : .available)
        self.platformProfiles = platformProfiles
        self.platformBalanceOwner = platformBalanceOwner
        self.historyContinuation = historyContinuation
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
        let balanceWindow: RateWindow? = if self.hasBalance {
            RateWindow(
                usedPercent: usedPercent,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: balanceDetail)
        } else {
            nil
        }

        let details = self.usageSummary.map {
            Self.detailSections(for: $0, referenceDate: self.updatedAt)
        } ?? []
        return UsageSnapshot(
            primary: balanceWindow,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            costUsage: self.usageSummary?.toCostUsageTokenSnapshot(),
            details: details,
            deepseekDetailedUsageState: self.detailedUsageState,
            deepseekPlatformProfiles: self.platformProfiles,
            deepseekPlatformBalanceOwner: self.platformBalanceOwner,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    func withPlatformBalanceOwner(_ owner: DeepSeekPlatformBalanceOwner?) -> DeepSeekUsageSnapshot {
        DeepSeekUsageSnapshot(
            hasBalance: self.hasBalance,
            isAvailable: self.isAvailable,
            currency: self.currency,
            totalBalance: self.totalBalance,
            grantedBalance: self.grantedBalance,
            toppedUpBalance: self.toppedUpBalance,
            usageSummary: self.usageSummary,
            detailedUsageState: self.detailedUsageState,
            platformProfiles: self.platformProfiles,
            platformBalanceOwner: self.hasBalance ? owner : nil,
            historyContinuation: self.historyContinuation,
            updatedAt: self.updatedAt)
    }

    public static func detailSections(
        for usage: DeepSeekUsageSummary,
        referenceDate: Date? = nil) -> [ProviderDetailSection]
    {
        let symbol = usage.currency == "CNY" ? "¥" : "$"
        let cost: (Double?) -> String = { value in
            value.map { "\(symbol)\(String(format: "%.4f", max(0, $0)))" } ?? "—"
        }
        let dayRowLabel = Self.singleDayRowLabel(for: usage, referenceDate: referenceDate)
        var rows: [ProviderDetailSection.Row] = [
            .makeRow(
                label: dayRowLabel,
                value: "\(cost(usage.todayCost)) · \(usage.todayTokens.formatted()) tokens"),
        ]
        let periodLabel = usage.periodLabel
        if periodLabel != "Today" {
            rows.append(.makeRow(
                label: periodLabel,
                value: "\(cost(usage.currentMonthCost)) · \(usage.currentMonthTokens.formatted()) tokens"))
        }
        rows.append(.makeRow(label: "Requests", value: "\(usage.currentMonthRequestCount)"))
        if usage.apiKeyCount > 0 {
            rows.append(.makeRow(label: "API keys", value: "\(usage.apiKeyCount)"))
        }
        if let topModel = usage.topModel {
            rows.append(.makeRow(label: "Top model", value: topModel))
        }
        let tokenChart: ProviderDetailSection.Chart? = usage.daily.isEmpty ? nil : .makeChart(
            title: "Daily tokens",
            unit: "tokens",
            points: usage.daily.map { ($0.date, Double($0.totalTokens)) })
        var sections = [ProviderDetailSection.makeSection(title: "Usage", rows: rows, chart: tokenChart)]
        let costPoints = usage.daily.compactMap { day -> (label: String, value: Double)? in
            guard let value = day.cost else { return nil }
            return (day.date, max(0, value))
        }
        let modelRows = usage.modelCosts.map { ProviderDetailSection.makeRow(label: $0.model, value: cost($0.cost)) }
        let hasCostChart = costPoints.contains { $0.value > 0 }
        if hasCostChart || !modelRows.isEmpty {
            sections.append(.makeSection(
                title: "Spend",
                rows: modelRows,
                chart: hasCostChart ? .makeChart(title: "Daily cost", unit: usage.currency, points: costPoints) : nil))
        }
        return sections
    }

    private static func singleDayRowLabel(for usage: DeepSeekUsageSummary, referenceDate: Date?) -> String {
        guard let referenceDate else { return "Today" }
        let calendar = Self.detailCalendar(for: usage)
        let summaryDayKey = CostUsageLocalDay.key(from: usage.updatedAt, calendar: calendar)
        let referenceDayKey = CostUsageLocalDay.key(from: referenceDate, calendar: calendar)
        return summaryDayKey == referenceDayKey ? "Today" : summaryDayKey
    }

    private static func detailCalendar(for usage: DeepSeekUsageSummary) -> Calendar {
        if usage.period == .currentMonth {
            return CostUsageBucketTimeZone.calendar(identifier: "UTC")
        }
        if let offset = usage.timeZoneSeconds, TimeZone(secondsFromGMT: offset) != nil {
            return CostUsageLocalDay.fixedOffsetGregorianCalendar(secondsFromGMT: offset)
        }
        return CostUsageLocalDay.gregorianCalendar(matching: .current)
    }
}

// MARK: - Errors

public enum DeepSeekUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidPlatformToken
    case rateLimited
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing DeepSeek API key."
        case .invalidPlatformToken:
            "DeepSeek Platform session is missing or expired."
        case .rateLimited:
            "DeepSeek API rate limit exceeded."
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

    private static let log = CodexBarLog.logger(LogCategories.provider(.deepseek, scope: "usage"))
    private static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    private static let usageAmountURL = URL(string: "https://platform.deepseek.com/api/v0/usage/amount")!
    private static let usageCostURL = URL(string: "https://platform.deepseek.com/api/v0/usage/cost")!
    private static let usageAmountByAPIKeyURL = URL(
        string: "https://platform.deepseek.com/api/v0/usage/by_api_key/amount")!
    private static let usageCostByAPIKeyURL = URL(
        string: "https://platform.deepseek.com/api/v0/usage/by_api_key/cost")!
    private static let platformUserSummaryURL = URL(
        string: "https://platform.deepseek.com/api/v0/users/get_user_summary")!
    private static let timeoutSeconds: TimeInterval = 15
    private static let optionalSummaryJoinGrace: Duration = .seconds(5)
    private static var apiCalendar: Calendar {
        CostUsageLocalDay.fixedOffsetGregorianCalendar(secondsFromGMT: 0)
    }

    private static var localGregorianCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .current
        return calendar
    }

    struct RecentUsageFetchResult: Sendable {
        let summary: DeepSeekUsageSummary
        let continuation: DeepSeekWideHistoryContinuation?
    }

    static func resolvedCalendar(bucketTimeZoneIdentifier: String) -> Calendar {
        let trimmed = bucketTimeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self.localGregorianCalendar }
        return CostUsageBucketTimeZone.calendar(identifier: trimmed)
    }

    public static func fetchUsage(
        apiKey: String,
        platformToken: String? = nil,
        includeOptionalUsage: Bool = true,
        period: CostReportingPeriod = .rolling(days: 30),
        bucketTimeZoneIdentifier: String = "") async throws -> DeepSeekUsageSnapshot
    {
        let calendar = self.resolvedCalendar(bucketTimeZoneIdentifier: bucketTimeZoneIdentifier)
        return try await self.fetchUsage(
            apiKey: apiKey,
            platformToken: platformToken,
            includeOptionalUsage: includeOptionalUsage,
            optionalSummaryJoinGrace: self.optionalSummaryJoinGrace,
            operations: FetchOperations(
                fetchBalanceData: { key in
                    try await self.fetchBalanceData(apiKey: key)
                },
                fetchSummary: { token in
                    try await self.fetchRecentUsageSummary(
                        platformToken: token,
                        profileID: nil,
                        period: period,
                        now: Date(),
                        localCalendar: calendar,
                        transport: ProviderHTTPClient.shared)
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
                fetchSummary: { token in
                    try await RecentUsageFetchResult(summary: fetchSummary(token), continuation: nil)
                }))
    }

    private struct FetchOperations: Sendable {
        let fetchBalanceData: @Sendable (String) async throws -> Data
        let fetchSummary: @Sendable (String) async throws -> RecentUsageFetchResult
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
        let summaryTask: Task<RecentUsageFetchResult, Error>? = if includeOptionalUsage, let usablePlatformToken {
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
                historyContinuation: completion.continuation,
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
        from task: Task<RecentUsageFetchResult, Error>,
        joinGrace: Duration) async throws
        -> (
            summary: DeepSeekUsageSummary?,
            continuation: DeepSeekWideHistoryContinuation?,
            state: DeepSeekDetailedUsageState)
    {
        let race = BoundedTaskJoin(sourceTask: task)
        switch await race.value(joinGrace: joinGrace) {
        case let .value(result):
            try Task.checkCancellation()
            return (result.summary, result.continuation, .available)
        case .timedOut:
            try Task.checkCancellation()
            Self.log.warning("DeepSeek detailed usage unavailable", metadata: ["reason": "timeout"])
            return (nil, nil, .unavailable)
        case let .failure(error):
            task.cancel()
            if Task.isCancelled {
                throw error
            }
            Self.log.warning(
                "DeepSeek detailed usage unavailable",
                metadata: ["reason": self.optionalSummaryFailureReason(error)])
            return (nil, nil, error is DeepSeekUsageError ? self.optionalSummaryFailureState(error) : .unavailable)
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
        case .rateLimited: return "rate_limited"
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
        period: CostReportingPeriod = .rolling(days: 30),
        now: Date = Date(),
        calendar: Calendar? = nil) async throws -> DeepSeekUsageSummary
    {
        try await self.fetchUsageSummary(
            platformToken: platformToken,
            period: period,
            now: now,
            calendar: calendar,
            transport: ProviderHTTPClient.shared)
    }

    static func fetchUsageSummary(
        platformToken: String,
        period: CostReportingPeriod = .rolling(days: 30),
        now: Date,
        calendar: Calendar? = nil,
        localCalendar: Calendar? = nil,
        transport: any ProviderHTTPTransport,
        shouldContinue: (@Sendable () async -> Bool)? = nil) async throws -> DeepSeekUsageSummary
    {
        let recent = try await self.fetchRecentUsageSummary(
            platformToken: platformToken,
            profileID: nil,
            period: period,
            now: now,
            calendar: calendar,
            localCalendar: localCalendar,
            transport: transport)
        guard let continuation = recent.continuation,
              continuation.metadata.plan.isWide
        else {
            return recent.summary
        }

        let plan = continuation.metadata.plan
        let olderWindows = Array(plan.chunks.dropFirst())
        let olderFolds: [DeepSeekUsageWindow: DeepSeekChunkFoldResult]
        let failedChunkCount: Int
        switch await Self.paginateOlderChunks(
            olderWindows: olderWindows,
            fetchChunk: continuation.fetchChunk,
            isStillValid: shouldContinue)
        {
        case .cancelled:
            throw CancellationError()
        case let .completed(folds, failures), let .invalidated(folds, failures):
            olderFolds = folds
            failedChunkCount = failures
        }

        let orderedFolds = [continuation.metadata.recentFold] + olderWindows.compactMap { olderFolds[$0] }
        return DeepSeekUsageCostParser.mergeByAPIKeyChunks(
            orderedFolds,
            plan: plan,
            failedChunkCount: failedChunkCount)
    }

    static func fetchRecentUsageSummary(
        platformToken: String,
        profileID: String?,
        period: CostReportingPeriod = .rolling(days: 30),
        now: Date = Date(),
        calendar: Calendar? = nil,
        localCalendar: Calendar? = nil,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> RecentUsageFetchResult
    {
        let baseCalendar = calendar ?? localCalendar ?? self.localGregorianCalendar
        let plan = DeepSeekHistoryPlan.make(period: period, now: now, calendar: baseCalendar)
        let monthlyCalendar = calendar ?? self.apiCalendar
        do {
            let recentFold = try await self.fetchByAPIKeyChunk(
                platformToken: platformToken,
                window: plan.recentChunk,
                calendar: plan.fixedOffsetCalendar,
                transport: transport)
            let summary = DeepSeekUsageCostParser.mergeByAPIKeyChunks([recentFold], plan: plan)
            let continuation = self.makeWideHistoryContinuation(
                platformToken: platformToken,
                profileID: profileID,
                plan: plan,
                recentFold: recentFold,
                transport: transport)
            return RecentUsageFetchResult(summary: summary, continuation: continuation)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw error
            }
            if let deepSeekError = error as? DeepSeekUsageError,
               deepSeekError == .invalidPlatformToken || deepSeekError == .rateLimited
            {
                throw deepSeekError
            }
            try Task.checkCancellation()
            Self.log.warning(
                "DeepSeek by-key usage unavailable, falling back to monthly totals",
                metadata: ["reason": self.optionalSummaryFailureReason(error)])
            let monthPeriod = try self.usagePeriod(now: now, calendar: monthlyCalendar)
            let payloads = try await self.fetchUsagePayloads(
                fetchAmount: {
                    try await self.fetchAmount(
                        platformToken: platformToken,
                        month: monthPeriod.month,
                        year: monthPeriod.year,
                        transport: transport)
                },
                fetchCost: {
                    try await self.fetchCost(
                        platformToken: platformToken,
                        month: monthPeriod.month,
                        year: monthPeriod.year,
                        transport: transport)
                })
            let monthlySummary = try DeepSeekUsageCostParser.parse(
                amountData: payloads.amount,
                costData: payloads.cost,
                now: now,
                calendar: monthlyCalendar)
            return RecentUsageFetchResult(summary: monthlySummary, continuation: nil)
        }
    }

    static func fetchByAPIKeyChunk(
        platformToken: String,
        window: DeepSeekUsageWindow,
        calendar: Calendar,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> DeepSeekChunkFoldResult
    {
        try Task.checkCancellation()
        let payloads = try await self.fetchUsagePayloads(
            fetchAmount: {
                try await self.fetchByAPIKey(
                    url: self.usageAmountByAPIKeyURL,
                    platformToken: platformToken,
                    window: window,
                    transport: transport)
            },
            fetchCost: {
                try await self.fetchByAPIKey(
                    url: self.usageCostByAPIKeyURL,
                    platformToken: platformToken,
                    window: window,
                    transport: transport)
            })
        return try DeepSeekUsageCostParser.foldByAPIKeyChunk(
            amountData: payloads.amount,
            costData: payloads.cost,
            window: window,
            calendar: calendar)
    }

    static func makeWideHistoryContinuation(
        platformToken: String,
        profileID: String?,
        plan: DeepSeekHistoryPlan,
        recentFold: DeepSeekChunkFoldResult,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) -> DeepSeekWideHistoryContinuation
    {
        let ownerDigest = DeepSeekPlatformBalanceOwner(
            profileID: profileID ?? "explicit",
            token: platformToken)?.tokenDigest
        let fixedCalendar = plan.fixedOffsetCalendar
        return DeepSeekWideHistoryContinuation(
            metadata: DeepSeekHistorySessionMetadata(
                profileID: profileID,
                ownerTokenDigest: ownerDigest,
                plan: plan,
                recentFold: recentFold),
            fetchChunk: { window in
                try await self.fetchByAPIKeyChunk(
                    platformToken: platformToken,
                    window: window,
                    calendar: fixedCalendar,
                    transport: transport)
            })
    }

    public static func fetchPlatformUsage(
        platformToken: String,
        includeOptionalUsage: Bool = true,
        period: CostReportingPeriod = .rolling(days: 30),
        bucketTimeZoneIdentifier: String = "",
        profileID: String? = nil) async throws -> DeepSeekUsageSnapshot
    {
        let calendar = self.resolvedCalendar(bucketTimeZoneIdentifier: bucketTimeZoneIdentifier)
        return try await self.fetchPlatformUsage(
            platformToken: platformToken,
            includeOptionalUsage: includeOptionalUsage,
            optionalSummaryJoinGrace: self.optionalSummaryJoinGrace,
            operations: PlatformFetchOperations(
                fetchBalance: { token in
                    try await self.fetchPlatformBalance(platformToken: token)
                },
                fetchSummary: { token in
                    try await self.fetchRecentUsageSummary(
                        platformToken: token,
                        profileID: profileID,
                        period: period,
                        now: Date(),
                        localCalendar: calendar,
                        transport: ProviderHTTPClient.shared)
                }))
    }

    static func _fetchPlatformUsageForTesting(
        includeOptionalUsage: Bool,
        optionalSummaryJoinGrace: Duration = .zero,
        fetchBalance: @escaping @Sendable () async throws -> DeepSeekUsageSnapshot,
        fetchSummary: @escaping @Sendable () async throws -> DeepSeekUsageSummary) async throws
        -> DeepSeekUsageSnapshot
    {
        try await self.fetchPlatformUsage(
            platformToken: "test-platform-token",
            includeOptionalUsage: includeOptionalUsage,
            optionalSummaryJoinGrace: optionalSummaryJoinGrace,
            operations: PlatformFetchOperations(
                fetchBalance: { _ in try await fetchBalance() },
                fetchSummary: { _ in try await RecentUsageFetchResult(summary: fetchSummary(), continuation: nil) }))
    }

    private struct PlatformFetchOperations: Sendable {
        let fetchBalance: @Sendable (String) async throws -> DeepSeekUsageSnapshot
        let fetchSummary: @Sendable (String) async throws -> RecentUsageFetchResult
    }

    private static func fetchPlatformUsage(
        platformToken: String,
        includeOptionalUsage: Bool,
        optionalSummaryJoinGrace: Duration,
        operations: PlatformFetchOperations) async throws -> DeepSeekUsageSnapshot
    {
        let token = platformToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw DeepSeekUsageError.invalidPlatformToken }

        let summaryTask: Task<RecentUsageFetchResult, Error>? = if includeOptionalUsage {
            Task {
                try await operations.fetchSummary(token)
            }
        } else {
            nil
        }

        let balance: DeepSeekUsageSnapshot
        do {
            balance = try await withTaskCancellationHandler {
                try await operations.fetchBalance(token)
            } onCancel: {
                summaryTask?.cancel()
            }
        } catch {
            summaryTask?.cancel()
            throw error
        }

        var snapshot = DeepSeekUsageSnapshot(
            isAvailable: balance.isAvailable,
            currency: balance.currency,
            totalBalance: balance.totalBalance,
            grantedBalance: balance.grantedBalance,
            toppedUpBalance: balance.toppedUpBalance,
            detailedUsageState: includeOptionalUsage ? .unavailable : .notRequested,
            updatedAt: balance.updatedAt)
        if let summaryTask {
            let completion = try await self.completedOptionalUsageSummary(
                from: summaryTask,
                joinGrace: optionalSummaryJoinGrace)
            snapshot = DeepSeekUsageSnapshot(
                isAvailable: balance.isAvailable,
                currency: balance.currency,
                totalBalance: balance.totalBalance,
                grantedBalance: balance.grantedBalance,
                toppedUpBalance: balance.toppedUpBalance,
                usageSummary: completion.summary,
                detailedUsageState: completion.state,
                historyContinuation: completion.continuation,
                updatedAt: balance.updatedAt)
        }
        return snapshot
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

    private static func applyPlatformHeaders(_ request: inout URLRequest, platformToken: String) {
        request.setValue("Bearer \(platformToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("web", forHTTPHeaderField: "x-client-platform")
        request.timeoutInterval = self.timeoutSeconds
    }

    private static func fetchByAPIKey(
        url: URL,
        platformToken: String,
        window: DeepSeekUsageWindow,
        transport: any ProviderHTTPTransport) async throws -> Data
    {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DeepSeekUsageError.networkError("Invalid URL")
        }
        components.queryItems = [
            URLQueryItem(name: "start", value: String(window.startSeconds)),
            URLQueryItem(name: "end", value: String(window.endSeconds)),
            URLQueryItem(name: "tz", value: String(window.timeZoneSeconds)),
        ]
        guard let requestURL = components.url else {
            throw DeepSeekUsageError.networkError("Could not construct URL")
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        self.applyPlatformHeaders(&request, platformToken: platformToken)
        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw DeepSeekUsageError.invalidPlatformToken
            }
            if response.statusCode == 429 {
                throw DeepSeekUsageError.rateLimited
            }
            throw DeepSeekUsageError.apiError("HTTP \(response.statusCode)")
        }
        return response.data
    }

    private static func usagePeriod(now: Date, calendar: Calendar) throws -> (month: Int, year: Int) {
        let monthComponents = calendar.dateComponents([.month, .year], from: now)
        guard let month = monthComponents.month, let year = monthComponents.year else {
            throw DeepSeekUsageError.parseFailed("Could not determine current month/year")
        }
        return (month: month, year: year)
    }

    private static func fetchAmount(
        platformToken: String,
        month: Int,
        year: Int,
        transport: any ProviderHTTPTransport) async throws -> Data
    {
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
        self.applyPlatformHeaders(&request, platformToken: platformToken)

        let response = try await transport.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw DeepSeekUsageError.invalidPlatformToken
            }
            throw DeepSeekUsageError.apiError("HTTP \(response.statusCode)")
        }

        return data
    }

    private static func fetchPlatformBalance(platformToken: String) async throws -> DeepSeekUsageSnapshot {
        var request = URLRequest(url: self.platformUserSummaryURL)
        request.httpMethod = "GET"
        self.applyPlatformHeaders(&request, platformToken: platformToken)

        let response = try await ProviderHTTPClient.shared.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw DeepSeekUsageError.invalidPlatformToken
            }
            throw DeepSeekUsageError.apiError("HTTP \(response.statusCode)")
        }
        return try self.parsePlatformBalance(data: response.data)
    }

    private static func fetchCost(
        platformToken: String,
        month: Int,
        year: Int,
        transport: any ProviderHTTPTransport) async throws -> Data
    {
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
        self.applyPlatformHeaders(&request, platformToken: platformToken)

        let response = try await transport.response(for: request)
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

    static func _parsePlatformBalanceForTesting(_ data: Data) throws -> DeepSeekUsageSnapshot {
        try self.parsePlatformBalance(data: data)
    }

    private static func parsePlatformBalance(data: Data) throws -> DeepSeekUsageSnapshot {
        let payload: DeepSeekPlatformUserSummaryResponse
        do {
            payload = try JSONDecoder().decode(DeepSeekPlatformUserSummaryResponse.self, from: data)
        } catch {
            throw DeepSeekUsageError.parseFailed(error.localizedDescription)
        }
        if let code = payload.code, code != 0 {
            if self.isPlatformAuthenticationError(code) {
                throw DeepSeekUsageError.invalidPlatformToken
            }
            throw DeepSeekUsageError.apiError("user summary code \(code)")
        }
        if let bizCode = payload.data?.bizCode, bizCode != 0 {
            if self.isPlatformAuthenticationError(bizCode) {
                throw DeepSeekUsageError.invalidPlatformToken
            }
            throw DeepSeekUsageError.apiError("user summary biz_code \(bizCode)")
        }
        guard let summary = payload.data?.bizData else {
            throw DeepSeekUsageError.parseFailed("Missing user summary biz_data")
        }

        let toppedUp = Dictionary(grouping: summary.normalWallets, by: \.currency)
            .mapValues { $0.reduce(0) { $0 + $1.balance } }
        let granted = Dictionary(grouping: summary.bonusWallets, by: \.currency)
            .mapValues { $0.reduce(0) { $0 + $1.balance } }
        let currencies = Set(toppedUp.keys).union(granted.keys).sorted()
        guard !currencies.isEmpty else {
            return DeepSeekUsageSnapshot(
                isAvailable: false,
                currency: "USD",
                totalBalance: 0,
                grantedBalance: 0,
                toppedUpBalance: 0,
                updatedAt: Date())
        }

        let selectedCurrency = currencies.first { currency in
            currency == "USD" && (toppedUp[currency, default: 0] + granted[currency, default: 0]) > 0
        } ?? currencies.first { currency in
            toppedUp[currency, default: 0] + granted[currency, default: 0] > 0
        } ?? currencies.first(where: { $0 == "USD" }) ?? currencies[0]
        let paidBalance = toppedUp[selectedCurrency, default: 0]
        let grantedBalance = granted[selectedCurrency, default: 0]
        let totalBalance = paidBalance + grantedBalance
        return DeepSeekUsageSnapshot(
            isAvailable: totalBalance > 0,
            currency: selectedCurrency,
            totalBalance: totalBalance,
            grantedBalance: grantedBalance,
            toppedUpBalance: paidBalance,
            updatedAt: Date())
    }

    private static func isPlatformAuthenticationError(_ code: Int) -> Bool {
        code == 40002 || code == 40003
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

package enum DeepSeekOlderChunkPaginationResult: Sendable {
    case completed(olderFolds: [DeepSeekUsageWindow: DeepSeekChunkFoldResult], failedChunkCount: Int)
    case invalidated(olderFolds: [DeepSeekUsageWindow: DeepSeekChunkFoldResult], failedChunkCount: Int)
    case cancelled
}

extension DeepSeekUsageFetcher {
    package static func paginateOlderChunks(
        olderWindows: [DeepSeekUsageWindow],
        reusableChunks: [DeepSeekUsageWindow: DeepSeekChunkFoldResult] = [:],
        fetchChunk: @Sendable (DeepSeekUsageWindow) async throws -> DeepSeekChunkFoldResult,
        isStillValid: (@Sendable () async -> Bool)? = nil) async -> DeepSeekOlderChunkPaginationResult
    {
        var olderFolds: [DeepSeekUsageWindow: DeepSeekChunkFoldResult] = [:]
        var failedChunkCount = 0

        for window in olderWindows {
            if Task.isCancelled { return .cancelled }
            if let isStillValid, await !isStillValid() {
                if Task.isCancelled { return .cancelled }
                return .invalidated(olderFolds: olderFolds, failedChunkCount: failedChunkCount)
            }
            if Task.isCancelled { return .cancelled }
            if let cached = reusableChunks[window] {
                olderFolds[window] = cached
                continue
            }
            do {
                let fold = try await fetchChunk(window)
                if Task.isCancelled { return .cancelled }
                olderFolds[window] = fold
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return .cancelled
                }
                if let deepSeekError = error as? DeepSeekUsageError,
                   deepSeekError == .invalidPlatformToken || deepSeekError == .rateLimited
                {
                    Self.log.warning(
                        "DeepSeek wide history stopped",
                        metadata: ["reason": self.optionalSummaryFailureReason(deepSeekError)])
                    break
                }
                failedChunkCount += 1
                Self.log.warning(
                    "DeepSeek older usage window unavailable",
                    metadata: ["reason": self.optionalSummaryFailureReason(error)])
            }
        }

        if Task.isCancelled { return .cancelled }
        return .completed(olderFolds: olderFolds, failedChunkCount: failedChunkCount)
    }
}
