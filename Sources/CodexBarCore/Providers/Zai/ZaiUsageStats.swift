import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Z.ai usage limit types from the API
public enum ZaiLimitType: String, Sendable {
    case timeLimit = "TIME_LIMIT"
    case tokensLimit = "TOKENS_LIMIT"
}

/// Z.ai usage limit unit types
public enum ZaiLimitUnit: Int, Sendable {
    case unknown = 0
    case days = 1
    case hours = 3
    case minutes = 5
    case weeks = 6
}

public enum ZaiUsageScope: String, CaseIterable, Codable, Sendable {
    case personal
    case team
}

public struct ZaiBigModelTeamContext: Equatable, Sendable {
    public let organizationID: String
    public let projectID: String

    public init?(organizationID: String?, projectID: String?) {
        guard let organizationID = ZaiSettingsReader.cleaned(organizationID),
              let projectID = ZaiSettingsReader.cleaned(projectID)
        else {
            return nil
        }
        self.organizationID = organizationID
        self.projectID = projectID
    }

    public init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(
            organizationID: environment[ZaiSettingsReader.bigModelOrganizationKey],
            projectID: environment[ZaiSettingsReader.bigModelProjectKey])
    }
}

/// A single limit entry from the z.ai API
public struct ZaiLimitEntry: Sendable {
    public let type: ZaiLimitType
    public let unit: ZaiLimitUnit
    public let number: Int
    public let usage: Int?
    public let currentValue: Int?
    public let remaining: Int?
    public let percentage: Double
    public let usageDetails: [ZaiUsageDetail]
    public let nextResetTime: Date?

    public init(
        type: ZaiLimitType,
        unit: ZaiLimitUnit,
        number: Int,
        usage: Int?,
        currentValue: Int?,
        remaining: Int?,
        percentage: Double,
        usageDetails: [ZaiUsageDetail],
        nextResetTime: Date?)
    {
        self.type = type
        self.unit = unit
        self.number = number
        self.usage = usage
        self.currentValue = currentValue
        self.remaining = remaining
        self.percentage = percentage
        self.usageDetails = usageDetails
        self.nextResetTime = nextResetTime
    }
}

extension ZaiLimitEntry {
    public var usedPercent: Double {
        if let computed = self.computedUsedPercent {
            return computed
        }
        // The raw API percentage can fall outside 0...100 (z.ai omits/misreports quota fields);
        // clamp it like computedUsedPercent and every sibling provider instead of surfacing it raw.
        return min(100, max(0, self.percentage))
    }

    public var windowMinutes: Int? {
        guard self.number > 0 else { return nil }
        switch self.unit {
        case .minutes:
            return self.number
        case .hours:
            return self.number * 60
        case .days:
            return self.number * 24 * 60
        case .weeks:
            return self.number * 7 * 24 * 60
        case .unknown:
            return nil
        }
    }

    public var windowDescription: String? {
        guard self.number > 0 else { return nil }
        let unitLabel: String? = switch self.unit {
        case .minutes: "minute"
        case .hours: "hour"
        case .days: "day"
        case .weeks: "week"
        case .unknown: nil
        }
        guard let unitLabel else { return nil }
        let suffix = self.number == 1 ? unitLabel : "\(unitLabel)s"
        return "\(self.number) \(suffix)"
    }

    public var windowLabel: String? {
        guard let description = self.windowDescription else { return nil }
        return "\(description) window"
    }

    var isMCPMonthlyMarker: Bool {
        self.type == .timeLimit && self.unit == .minutes && self.number == 1
    }

    private var computedUsedPercent: Double? {
        guard let limit = self.usage, limit > 0 else { return nil }

        // z.ai sometimes omits quota fields; don't invent zeros (can yield 100% used incorrectly).
        var usedRaw: Int?
        if let remaining = self.remaining {
            let usedFromRemaining = limit - remaining
            if let currentValue = self.currentValue {
                usedRaw = max(usedFromRemaining, currentValue)
            } else {
                usedRaw = usedFromRemaining
            }
        } else if let currentValue = self.currentValue {
            usedRaw = currentValue
        }
        guard let usedRaw else { return nil }

        let used = max(0, min(limit, usedRaw))
        let percent = (Double(used) / Double(limit)) * 100
        return min(100, max(0, percent))
    }
}

/// Usage detail for MCP tools
public struct ZaiUsageDetail: Sendable, Codable {
    public let modelCode: String
    public let usage: Int

    public init(modelCode: String, usage: Int) {
        self.modelCode = modelCode
        self.usage = usage
    }
}

/// Complete z.ai usage response
public struct ZaiUsageSnapshot: Sendable {
    public let tokenLimit: ZaiLimitEntry?
    /// Shorter-window TOKENS_LIMIT (e.g. 5-hour), present only when the API returns two TOKENS_LIMIT entries.
    public let sessionTokenLimit: ZaiLimitEntry?
    public let timeLimit: ZaiLimitEntry?
    public let planName: String?
    public let modelUsage: ZaiModelUsageData?
    /// Daily-granularity per-model usage (last ~30 days) for the 7-day/30-day chart ranges.
    /// The `model-usage` endpoint returns hourly buckets only for short windows, so the longer
    /// ranges need a separate wide-window fetch rather than aggregating `modelUsage`.
    public let dailyModelUsage: ZaiModelUsageData?
    public let updatedAt: Date

    public init(
        tokenLimit: ZaiLimitEntry?,
        sessionTokenLimit: ZaiLimitEntry? = nil,
        timeLimit: ZaiLimitEntry?,
        planName: String?,
        modelUsage: ZaiModelUsageData? = nil,
        dailyModelUsage: ZaiModelUsageData? = nil,
        updatedAt: Date)
    {
        self.tokenLimit = tokenLimit
        self.sessionTokenLimit = sessionTokenLimit
        self.timeLimit = timeLimit
        self.planName = planName
        self.modelUsage = modelUsage
        self.dailyModelUsage = dailyModelUsage
        self.updatedAt = updatedAt
    }

    /// Returns true if this snapshot contains valid z.ai data
    public var isValid: Bool {
        self.tokenLimit != nil || self.timeLimit != nil
    }
}

extension ZaiUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let primaryLimit = self.sessionTokenLimit ?? self.tokenLimit ?? self.timeLimit
        let secondaryLimit = self.sessionTokenLimit == nil ? nil : self.tokenLimit
        let primary = primaryLimit.map { Self.rateWindow(for: $0) } ?? RateWindow(
            usedPercent: 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: nil)
        let secondary = secondaryLimit.map { Self.rateWindow(for: $0) }
        let hasCodingLimit = self.tokenLimit != nil || self.sessionTokenLimit != nil
        let extraRateWindows = hasCodingLimit ? self.timeLimit.map {
            [NamedRateWindow(id: "zai-mcp", title: "MCP", window: Self.rateWindow(for: $0))]
        } : nil

        let planName = self.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginMethod = (planName?.isEmpty ?? true) ? nil : planName
        let identity = ProviderIdentitySnapshot(
            providerID: .zai,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginMethod)
        var quotaRows: [ProviderDetailSection.Row] = []
        if let tokenLimit = self.tokenLimit {
            quotaRows.append(Self.detailRow(label: "Token quota", limit: tokenLimit))
        }
        if let sessionTokenLimit = self.sessionTokenLimit {
            quotaRows.append(Self.detailRow(label: "Session token quota", limit: sessionTokenLimit))
        }
        if let timeLimit = self.timeLimit {
            quotaRows.append(Self.detailRow(label: "MCP quota", limit: timeLimit))
            quotaRows.append(contentsOf: timeLimit.usageDetails.prefix(20).map {
                .makeRow(label: $0.modelCode, value: "\($0.usage)")
            })
        }
        var details: [ProviderDetailSection] = [
            .makeSection(title: "Quota details", rows: quotaRows),
        ]
        if let modelUsage = self.modelUsage {
            details.append(Self.modelUsageSection(title: "Hourly tokens", data: modelUsage))
        }
        if let dailyModelUsage = self.dailyModelUsage {
            details.append(Self.modelUsageSection(title: "Daily tokens", data: dailyModelUsage))
        }
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            extraRateWindows: extraRateWindows,
            providerCost: nil,
            details: details,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func detailRow(label: String, limit: ZaiLimitEntry) -> ProviderDetailSection.Row {
        let secondary = [
            limit.usage.map { "\($0) limit" },
            limit.remaining.map { "\($0) remaining" },
        ].compactMap(\.self).joined(separator: " · ")
        return .makeRow(
            label: label,
            value: Self.percentString(limit.usedPercent),
            secondaryValue: secondary.isEmpty ? nil : secondary)
    }

    private static func modelUsageSection(title: String, data: ZaiModelUsageData) -> ProviderDetailSection {
        var totals: [(name: String, tokens: Int)] = []
        for item in data.modelDataList {
            let tokens = item.tokensUsage.compactMap(\.self).filter { $0 > 0 }.reduce(0, +)
            if tokens > 0 {
                totals.append((item.modelName ?? "Unknown", tokens))
            }
        }
        totals.sort {
            $0.tokens == $1.tokens ? $0.name < $1.name : $0.tokens > $1.tokens
        }
        let points = data.xTime.enumerated().compactMap { index, label -> (String, Double)? in
            let total = data.modelDataList.reduce(0) { partial, item in
                guard index < item.tokensUsage.count, let value = item.tokensUsage[index], value > 0 else {
                    return partial
                }
                return partial + value
            }
            return total > 0 ? (label, Double(total)) : nil
        }
        return .makeSection(
            title: title,
            rows: totals.prefix(20).map {
                ProviderDetailSection.Row.makeRow(label: $0.name, value: "\($0.tokens)")
            },
            chart: .makeChart(title: title, unit: "tokens", points: points))
    }

    private static func percentString(_ value: Double) -> String {
        value == value.rounded()
            ? String(format: "%.0f%% used", value)
            : String(format: "%.1f%% used", value)
    }

    private static func rateWindow(for limit: ZaiLimitEntry) -> RateWindow {
        RateWindow(
            usedPercent: limit.usedPercent,
            windowMinutes: limit.type == .tokensLimit ? limit.windowMinutes : nil,
            resetsAt: limit.nextResetTime,
            resetDescription: self.resetDescription(for: limit))
    }

    private static func resetDescription(for limit: ZaiLimitEntry) -> String? {
        if limit.type == .timeLimit {
            return "MCP"
        }
        if limit.type == .tokensLimit, limit.windowMinutes == 5 * 60 {
            return "5-hour"
        }
        if let label = limit.windowLabel {
            return label
        }
        return nil
    }
}

/// Z.ai quota limit API response
private struct ZaiQuotaLimitResponse: Decodable {
    let code: Int
    let msg: String?
    let data: ZaiQuotaLimitData?
    let success: Bool

    var isSuccess: Bool {
        self.success && self.code == 200
    }

    var errorMessage: String {
        let message = self.msg?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty {
            return message
        }
        return "Z.ai quota API returned code \(self.code)"
    }
}

private struct ZaiQuotaLimitData: Decodable {
    let limits: [ZaiLimitRaw]
    let planName: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.limits = try container.decodeIfPresent([ZaiLimitRaw].self, forKey: .limits) ?? []
        let rawPlan = try [
            container.decodeIfPresent(String.self, forKey: .planName),
            container.decodeIfPresent(String.self, forKey: .plan),
            container.decodeIfPresent(String.self, forKey: .planType),
            container.decodeIfPresent(String.self, forKey: .packageName),
            container.decodeIfPresent(String.self, forKey: .level),
        ].compactMap(\.self).first
        let trimmed = rawPlan?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.planName = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case limits
        case planName
        case plan
        case planType = "plan_type"
        case packageName
        case level
    }
}

private struct ZaiLimitRaw: Codable {
    let type: String
    let unit: Int
    let number: Int
    let usage: Int?
    let currentValue: Int?
    let remaining: Int?
    let percentage: Int
    let usageDetails: [ZaiUsageDetail]?
    let nextResetTime: Int?

    func toLimitEntry() -> ZaiLimitEntry? {
        guard let limitType = ZaiLimitType(rawValue: type) else { return nil }
        let limitUnit = ZaiLimitUnit(rawValue: unit) ?? .unknown
        let nextReset = self.nextResetTime.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        return ZaiLimitEntry(
            type: limitType,
            unit: limitUnit,
            number: self.number,
            usage: self.usage,
            currentValue: self.currentValue,
            remaining: self.remaining,
            percentage: Double(self.percentage),
            usageDetails: self.usageDetails ?? [],
            nextResetTime: nextReset)
    }
}

/// Fetches usage stats from the z.ai API
public struct ZaiUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.provider(.zai, scope: "usage"))

    /// Path for z.ai quota API
    private static let quotaAPIPath = "api/monitor/usage/quota/limit"

    /// Resolves the quota URL using (in order):
    /// 1) `Z_AI_QUOTA_URL` environment override (full URL).
    /// 2) `Z_AI_API_HOST` environment override (host/base URL).
    /// 3) Region selection (global default).
    public static func resolveQuotaURL(
        region: ZaiAPIRegion,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = ZaiSettingsReader.quotaURL(environment: environment) {
            return override
        }
        if let host = ZaiSettingsReader.apiHost(environment: environment),
           let hostURL = self.quotaURL(baseURLString: host)
        {
            return hostURL
        }
        return region.quotaLimitURL
    }

    /// Resolves the canonical dashboard for the effective quota endpoint without opening custom override hosts.
    public static func resolveDashboardURL(
        region: ZaiAPIRegion,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        usageScope: ZaiUsageScope = .personal) -> URL
    {
        let quotaHost = self.resolveQuotaURL(region: region, environment: environment).host?.lowercased()
        if quotaHost == ZaiAPIRegion.global.quotaLimitURL.host?.lowercased() {
            return usageScope == .team ? ZaiAPIRegion.global.teamDashboardURL : ZaiAPIRegion.global.dashboardURL
        }
        if quotaHost == ZaiAPIRegion.bigmodelCN.quotaLimitURL.host?.lowercased() {
            return usageScope == .team ? ZaiAPIRegion.bigmodelCN.teamDashboardURL : ZaiAPIRegion.bigmodelCN.dashboardURL
        }
        return usageScope == .team ? region.teamDashboardURL : region.dashboardURL
    }

    /// Fetches usage stats from z.ai using the provided API key
    public static func fetchUsage(
        apiKey: String,
        region: ZaiAPIRegion = .global,
        usageScope: ZaiUsageScope? = nil,
        teamContext: ZaiBigModelTeamContext? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> ZaiUsageSnapshot
    {
        guard !apiKey.isEmpty else {
            throw ZaiUsageError.invalidCredentials
        }
        try ZaiSettingsReader.validateQuotaEndpointOverride(region: region, environment: environment)

        let resolvedScope = usageScope ?? .personal
        let quotaURL = try self.requestURL(
            baseURL: self.resolveQuotaURL(region: region, environment: environment),
            usageScope: resolvedScope)
        let resolvedTeamContext = try self.resolvedTeamContext(
            usageScope: resolvedScope,
            explicit: teamContext,
            environment: environment)

        var request = URLRequest(url: quotaURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        self.applyTeamHeaders(resolvedTeamContext, to: &request)

        let response = try await transport.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            Self.log.error("z.ai API returned \(response.statusCode): \(errorMessage)")
            throw ZaiUsageError.apiError("HTTP \(response.statusCode): \(errorMessage)")
        }

        // Some upstream issues (wrong endpoint/region/proxy) can yield HTTP 200 with an empty body.
        // JSONDecoder will otherwise throw an opaque Cocoa error ("data is missing").
        guard !data.isEmpty else {
            Self.log.error("z.ai API returned empty body (HTTP 200) for \(Self.safeURLForLogging(quotaURL))")
            throw ZaiUsageError.parseFailed(
                "Empty response body (HTTP 200). Check z.ai API region (Global vs BigModel CN) and your API token.")
        }

        // Log raw response for debugging
        if let jsonString = String(data: data, encoding: .utf8) {
            Self.log.debug("z.ai API response: \(jsonString)")
        }

        do {
            return try Self.parseUsageSnapshot(from: data)
        } catch let error as DecodingError {
            Self.log.error("z.ai JSON decoding error: \(error.localizedDescription)")
            throw ZaiUsageError.parseFailed(error.localizedDescription)
        } catch let error as ZaiUsageError {
            throw error
        } catch {
            Self.log.error("z.ai parsing error: \(error.localizedDescription)")
            throw ZaiUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func safeURLForLogging(_ url: URL) -> String {
        let host = url.host ?? "<unknown-host>"
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        return "\(host)\(port)\(path)"
    }

    private static func requestURL(baseURL: URL, usageScope: ZaiUsageScope) throws -> URL {
        guard usageScope == .team else { return baseURL }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ZaiUsageError.networkError("Invalid URL")
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "type" }
        items.append(URLQueryItem(name: "type", value: "2"))
        components.queryItems = items
        guard let url = components.url else {
            throw ZaiUsageError.networkError("Invalid URL")
        }
        return url
    }

    private static func resolvedTeamContext(
        usageScope: ZaiUsageScope,
        explicit: ZaiBigModelTeamContext?,
        environment: [String: String]) throws -> ZaiBigModelTeamContext?
    {
        guard usageScope == .team else { return nil }
        if let explicit {
            return explicit
        }
        if let context = ZaiBigModelTeamContext(environment: environment) {
            return context
        }
        throw ZaiUsageError.missingTeamContext
    }

    private static func applyTeamHeaders(_ context: ZaiBigModelTeamContext?, to request: inout URLRequest) {
        guard let context else { return }
        request.setValue(context.organizationID, forHTTPHeaderField: "Bigmodel-Organization")
        request.setValue(context.projectID, forHTTPHeaderField: "Bigmodel-Project")
    }

    static func parseUsageSnapshot(from data: Data) throws -> ZaiUsageSnapshot {
        guard !data.isEmpty else {
            throw ZaiUsageError.parseFailed("Empty response body")
        }

        let decoder = JSONDecoder()
        let apiResponse = try decoder.decode(ZaiQuotaLimitResponse.self, from: data)

        guard apiResponse.isSuccess else {
            throw ZaiUsageError.apiError(apiResponse.errorMessage)
        }

        guard let responseData = apiResponse.data else {
            throw ZaiUsageError.parseFailed("Missing data")
        }

        var tokenLimits: [ZaiLimitEntry] = []
        var timeLimit: ZaiLimitEntry?

        for limit in responseData.limits {
            if let entry = limit.toLimitEntry() {
                switch entry.type {
                case .tokensLimit:
                    tokenLimits.append(entry)
                case .timeLimit:
                    timeLimit = entry
                }
            }
        }

        // Multiple TOKENS_LIMIT entries: shortest window → sessionTokenLimit (tertiary),
        // longest → tokenLimit (primary).
        let tokenLimit: ZaiLimitEntry?
        let sessionTokenLimit: ZaiLimitEntry?
        if tokenLimits.count >= 2 {
            let sorted = tokenLimits.sorted {
                ($0.windowMinutes ?? Int.max) < ($1.windowMinutes ?? Int.max)
            }
            sessionTokenLimit = sorted.first
            tokenLimit = sorted.last
        } else {
            tokenLimit = tokenLimits.first
            sessionTokenLimit = nil
        }

        return ZaiUsageSnapshot(
            tokenLimit: tokenLimit,
            sessionTokenLimit: sessionTokenLimit,
            timeLimit: timeLimit,
            planName: responseData.planName,
            modelUsage: nil,
            updatedAt: Date())
    }

    private static func quotaURL(baseURLString: String) -> URL? {
        guard let cleaned = ZaiSettingsReader.cleaned(baseURLString) else { return nil }
        guard let url = ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: cleaned) else { return nil }
        if url.path.isEmpty || url.path == "/" {
            return url.appendingPathComponent(Self.quotaAPIPath)
        }
        return url
    }
}

// MARK: - Model Usage Data

/// Per-model hourly token usage from the z.ai model-usage API
public struct ZaiModelUsageData: Sendable {
    public let xTime: [String]
    public let modelDataList: [ZaiModelDataItem]

    public init(xTime: [String], modelDataList: [ZaiModelDataItem]) {
        self.xTime = xTime
        self.modelDataList = modelDataList
    }

    public var modelNames: [String] {
        self.modelDataList.compactMap(\.modelName)
    }
}

public struct ZaiModelDataItem: Sendable {
    public let modelName: String?
    public let tokensUsage: [Int?]

    public init(modelName: String?, tokensUsage: [Int?]) {
        self.modelName = modelName
        self.tokensUsage = tokensUsage
    }
}

// MARK: - Hourly Chart Data

public enum ZaiHourlyRange: Equatable, Sendable {
    case today(referenceDate: Date)
    case last24h
    case last7d
    case last30d

    public var isToday: Bool {
        if case .today = self {
            return true
        }
        return false
    }

    /// Daily ranges read the wide-window (daily-granularity) dataset and render one bar per day.
    public var isDaily: Bool {
        switch self {
        case .last7d, .last30d: true
        case .today, .last24h: false
        }
    }
}

public struct ZaiHourlyBar: Sendable {
    public let label: String
    public let segments: [(model: String, tokens: Int)]

    public init(label: String, segments: [(model: String, tokens: Int)]) {
        self.label = label
        self.segments = segments
    }

    public var totalTokens: Int {
        self.segments.reduce(0) { $0 + $1.tokens }
    }
}

public enum ZaiHourlyBars: Sendable {
    public static func from(modelData: ZaiModelUsageData, range: ZaiHourlyRange, now: Date = Date()) -> [ZaiHourlyBar] {
        switch range {
        case .today, .last24h:
            self.hourlyBars(modelData: modelData, range: range, now: now)
        case .last7d:
            self.dailyBars(modelData: modelData, days: 7, now: now)
        case .last30d:
            self.dailyBars(modelData: modelData, days: 30, now: now)
        }
    }

    private static func hourlyBars(modelData: ZaiModelUsageData, range: ZaiHourlyRange, now: Date) -> [ZaiHourlyBar] {
        let calendar = Calendar.current
        let referenceDate: Date = if case let .today(ref) = range {
            ref
        } else {
            now
        }
        let cutoff: Date = if case .today = range {
            calendar.startOfDay(for: referenceDate)
        } else {
            calendar.date(byAdding: .hour, value: -24, to: now) ?? now
        }

        var bars: [ZaiHourlyBar] = []
        for (index, timeString) in modelData.xTime.enumerated() {
            guard let hourDate = parseHourDate(timeString), hourDate >= cutoff else { continue }
            let segments = self.segments(modelData: modelData, index: index)
            guard !segments.isEmpty else { continue }
            bars.append(ZaiHourlyBar(label: self.formatHourLabel(hourDate), segments: segments))
        }
        return bars
    }

    private static func dailyBars(modelData: ZaiModelUsageData, days: Int, now: Date) -> [ZaiHourlyBar] {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? now

        var bars: [ZaiHourlyBar] = []
        for (index, timeString) in modelData.xTime.enumerated() {
            guard let dayDate = parseDayDate(timeString), dayDate >= cutoff else { continue }
            let segments = self.segments(modelData: modelData, index: index)
            guard !segments.isEmpty else { continue }
            bars.append(ZaiHourlyBar(label: self.formatDayLabel(dayDate), segments: segments))
        }
        return bars
    }

    private static func segments(modelData: ZaiModelUsageData, index: Int) -> [(model: String, tokens: Int)] {
        var segments: [(model: String, tokens: Int)] = []
        for item in modelData.modelDataList {
            guard index < item.tokensUsage.count,
                  let tokenCount = item.tokensUsage[index], tokenCount > 0
            else { continue }
            segments.append((model: item.modelName ?? "Unknown", tokens: tokenCount))
        }
        return segments
    }

    public static func parseHourDate(_ string: String) -> Date? {
        self.date(from: string, format: "yyyy-MM-dd HH:mm")
    }

    public static func parseDayDate(_ string: String) -> Date? {
        self.date(from: string, format: "yyyy-MM-dd")
    }

    private static func date(from string: String, format: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string)
    }

    private static func formatHourLabel(_ hourDate: Date) -> String {
        self.label(from: hourDate, format: "HH")
    }

    private static func formatDayLabel(_ dayDate: Date) -> String {
        self.label(from: dayDate, format: "MM-dd")
    }

    private static func label(from date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

// MARK: - Model Usage Fetcher Extension

extension ZaiUsageFetcher {
    /// Fetches per-model token usage. The `model-usage` endpoint returns granularity by span:
    /// a short window (`daysBack: 1`) yields hourly buckets (`xTime` like "2026-07-31 14:00"),
    /// while a long window (`daysBack: 30`) yields daily buckets (`xTime` like "2026-07-31").
    public static func fetchModelUsage(
        apiKey: String,
        region: ZaiAPIRegion = .global,
        usageScope: ZaiUsageScope? = nil,
        teamContext: ZaiBigModelTeamContext? = nil,
        daysBack: Int = 1,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> ZaiModelUsageData
    {
        guard !apiKey.isEmpty else {
            throw ZaiUsageError.invalidCredentials
        }
        try ZaiSettingsReader.validateAPIHostEndpointOverride(region: region, environment: environment)

        let resolvedScope = usageScope ?? .personal
        let resolvedTeamContext = try self.resolvedTeamContext(
            usageScope: resolvedScope,
            explicit: teamContext,
            environment: environment)

        let baseURL: URL = if let host = ZaiSettingsReader.apiHost(environment: environment),
                              let resolved = Self.modelUsageURL(baseURLString: host)
        {
            resolved
        } else {
            region.modelUsageURL
        }

        let now = Date()
        let calendar = Calendar.current
        guard let startDate = calendar.date(byAdding: .day, value: -max(1, daysBack), to: calendar.startOfDay(for: now))
        else {
            throw ZaiUsageError.parseFailed("Invalid date calculation")
        }

        let startComponents = calendar.dateComponents([.year, .month, .day, .hour], from: startDate)
        let endComponents = calendar.dateComponents([.year, .month, .day, .hour], from: now)
        let startTime = String(
            format: "%04d-%02d-%02d %02d:00:00",
            startComponents.year!,
            startComponents.month!,
            startComponents.day!,
            startComponents.hour!)
        let endTime = String(
            format: "%04d-%02d-%02d %02d:59:59",
            endComponents.year!,
            endComponents.month!,
            endComponents.day!,
            endComponents.hour!)

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ZaiUsageError.networkError("Invalid URL")
        }
        components.queryItems = [
            URLQueryItem(name: "startTime", value: startTime),
            URLQueryItem(name: "endTime", value: endTime),
        ]
        if resolvedScope == .team {
            components.queryItems?.append(URLQueryItem(name: "type", value: "3"))
        }

        guard let requestURL = components.url else {
            throw ZaiUsageError.networkError("Invalid URL")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        self.applyTeamHeaders(resolvedTeamContext, to: &request)

        let response = try await transport.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            Self.log.error("z.ai model-usage API returned \(response.statusCode): \(errorMessage)")
            throw ZaiUsageError.apiError("HTTP \(response.statusCode): \(errorMessage)")
        }

        guard !data.isEmpty else { return ZaiModelUsageData(xTime: [], modelDataList: []) }

        return try Self.parseModelUsage(from: data)
    }

    static func parseModelUsage(from data: Data) throws -> ZaiModelUsageData {
        let decoder = JSONDecoder()
        let apiResponse = try decoder.decode(ZaiModelUsageAPIResponse.self, from: data)

        guard apiResponse.isSuccess else {
            throw ZaiUsageError.apiError(apiResponse.msg)
        }

        guard let responseData = apiResponse.data else {
            return ZaiModelUsageData(xTime: [], modelDataList: [])
        }

        let items = responseData.modelDataList?.map { raw in
            ZaiModelDataItem(
                modelName: raw.modelName,
                tokensUsage: raw.tokensUsage ?? [])
        } ?? []

        return ZaiModelUsageData(
            xTime: responseData.xTime ?? [],
            modelDataList: items)
    }

    /// Fetches required quota data and attaches optional model usage when available.
    public static func fetchUsageWithModelUsage(
        apiKey: String,
        region: ZaiAPIRegion = .global,
        usageScope: ZaiUsageScope? = nil,
        teamContext: ZaiBigModelTeamContext? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> ZaiUsageSnapshot
    {
        try ZaiSettingsReader.validateEndpointOverrides(region: region, environment: environment)
        let snapshot = try await Self.fetchUsage(
            apiKey: apiKey,
            region: region,
            usageScope: usageScope,
            teamContext: teamContext,
            environment: environment,
            transport: transport)
        let modelUsage: ZaiModelUsageData?
        do {
            modelUsage = try await Self.fetchModelUsage(
                apiKey: apiKey,
                region: region,
                usageScope: usageScope,
                teamContext: teamContext,
                environment: environment,
                transport: transport)
        } catch {
            Self.log.info("z.ai model usage fetch failed (non-fatal): \(error.localizedDescription)")
            modelUsage = nil
        }

        // Wide-window daily fetch powers the 7-day / 30-day chart ranges. The endpoint only
        // returns hourly buckets for short windows, so this is a separate request.
        let dailyModelUsage: ZaiModelUsageData?
        do {
            dailyModelUsage = try await Self.fetchModelUsage(
                apiKey: apiKey,
                region: region,
                usageScope: usageScope,
                teamContext: teamContext,
                daysBack: 30,
                environment: environment,
                transport: transport)
        } catch {
            Self.log.info("z.ai daily model usage fetch failed (non-fatal): \(error.localizedDescription)")
            dailyModelUsage = nil
        }

        guard modelUsage != nil || dailyModelUsage != nil else { return snapshot }

        return ZaiUsageSnapshot(
            tokenLimit: snapshot.tokenLimit,
            sessionTokenLimit: snapshot.sessionTokenLimit,
            timeLimit: snapshot.timeLimit,
            planName: snapshot.planName,
            modelUsage: modelUsage,
            dailyModelUsage: dailyModelUsage,
            updatedAt: snapshot.updatedAt)
    }

    private static func modelUsageURL(baseURLString: String) -> URL? {
        guard let cleaned = ZaiSettingsReader.cleaned(baseURLString) else { return nil }
        let path = "api/monitor/usage/model-usage"
        guard let url = ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: cleaned) else { return nil }
        if url.path.isEmpty || url.path == "/" {
            return url.appendingPathComponent(path)
        }
        return url
    }
}

// MARK: - Model Usage API Response (private)

private struct ZaiModelUsageAPIResponse: Decodable {
    let code: Int
    let msg: String
    let data: ZaiModelUsageRawData?
    let success: Bool

    var isSuccess: Bool {
        self.success && self.code == 200
    }
}

private struct ZaiModelUsageRawData: Decodable {
    let xTime: [String]?
    let modelDataList: [ZaiModelDataItemRaw]?

    enum CodingKeys: String, CodingKey {
        case xTime = "x_time"
        case modelDataList
    }
}

private struct ZaiModelDataItemRaw: Decodable {
    let modelName: String?
    let tokensUsage: [Int?]?
}

/// Errors that can occur during z.ai usage fetching
public enum ZaiUsageError: LocalizedError, Sendable {
    case invalidCredentials
    case missingTeamContext
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Invalid z.ai API credentials"
        case .missingTeamContext:
            "z.ai BigModel team usage requires both Organization ID and Project ID."
        case let .networkError(message):
            "z.ai network error: \(message)"
        case let .apiError(message):
            "z.ai API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse z.ai response: \(message)"
        }
    }
}
