import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum BifrostUsageError: LocalizedError, Sendable {
    case missingCredentials
    case missingBaseURL
    case invalidEndpointOverride(String)
    case unauthorized
    case keyExpired
    case inactiveKey
    case invalidURL
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Bifrost virtual key. Set apiKey in ~/.codexbar/config.json or BIFROST_API_KEY."
        case .missingBaseURL:
            "Missing Bifrost base URL. Set enterpriseHost in ~/.codexbar/config.json or BIFROST_BASE_URL."
        case let .invalidEndpointOverride(key):
            "Bifrost base URL override \(key) is invalid. Use an HTTPS URL, or plain HTTP for " +
                "loopback or private-network addresses and .local hosts, without embedded credentials."
        case .unauthorized:
            "Bifrost rejected the virtual key."
        case .keyExpired:
            "Bifrost virtual key has expired."
        case .inactiveKey:
            "Bifrost virtual key is inactive and has no budgets or rate limits to display."
        case .invalidURL:
            "Bifrost URL is invalid."
        case let .apiError(message):
            "Bifrost API error: \(message)"
        case let .parseFailed(message):
            "Bifrost parse error: \(message)"
        }
    }
}

public struct BifrostUsageSnapshot: Codable, Sendable, Equatable {
    public struct ModelUsage: Codable, Sendable, Equatable {
        public let model: String?
        public let provider: String?
        public let totalRequests: Int?
        public let totalTokens: Int?
        public let totalCost: Double?
    }

    public struct Budget: Codable, Sendable, Equatable {
        public let id: String
        public let maxLimit: Double
        public let resetDuration: String?
        public let lastReset: Date?
        public let currentUsage: Double
        public let overrideAmount: Double
        public let overrideMode: String?
        public let overrideCyclesRemaining: Int?
        public let sourceName: String?
        public let perModelUsage: [ModelUsage]

        public var hasActiveOverride: Bool {
            guard self.overrideAmount > 0 else { return false }
            switch self.overrideMode {
            case "forever":
                return true
            case "cycles":
                return (self.overrideCyclesRemaining ?? 0) > 0
            default:
                return false
            }
        }

        public var effectiveMaxLimit: Double {
            self.hasActiveOverride ? self.maxLimit + self.overrideAmount : self.maxLimit
        }

        var durationSeconds: Double? {
            BifrostResetDuration.parse(self.resetDuration)?.seconds
        }
    }

    public struct RateLimit: Codable, Sendable, Equatable {
        public let id: String?
        public let sourceName: String?
        public let tokenMaxLimit: Double?
        public let tokenCurrentUsage: Double
        public let tokenResetDuration: String?
        public let tokenLastReset: Date?
        public let requestMaxLimit: Double?
        public let requestCurrentUsage: Double
        public let requestResetDuration: String?
        public let requestLastReset: Date?
    }

    public let virtualKeyName: String?
    public let isActive: Bool
    public let budgets: [Budget]
    public let rateLimits: [RateLimit]
    public let updatedAt: Date

    public func toUsageSnapshot() -> UsageSnapshot {
        let sortedBudgets = self.budgets.sorted {
            let lhs = $0.durationSeconds ?? .infinity
            let rhs = $1.durationSeconds ?? .infinity
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }

        let windowCandidates = sortedBudgets.compactMap { budget -> (Budget, RateWindow)? in
            guard let window = Self.budgetWindow(budget, now: self.updatedAt) else { return nil }
            return (budget, window)
        }

        let primary = windowCandidates.first?.1
        let secondary = windowCandidates.count > 1 ? windowCandidates[1].1 : nil
        let extraBudgetWindows = windowCandidates.dropFirst(2).map { budget, window in
            NamedRateWindow(
                id: "bifrost-budget-\(budget.id)",
                title: budget.sourceName ?? "Budget",
                window: window)
        }

        let rateLimitWindows = self.rateLimitNamedWindows()
        let extraRateWindows = extraBudgetWindows + rateLimitWindows

        let providerCostBudget = sortedBudgets.first
        let providerCost = providerCostBudget.flatMap { self.providerCostSnapshot(from: $0) }

        var details: [ProviderDetailSection] = []
        if let modelSection = providerCostBudget.flatMap(self.modelUsageSection) {
            details.append(modelSection)
        }
        if sortedBudgets.count > 1 {
            details.append(self.budgetsSection(sortedBudgets))
        }

        var allExtraWindows = extraRateWindows
        if !self.isActive, primary != nil || secondary != nil || !extraRateWindows.isEmpty {
            allExtraWindows.insert(
                NamedRateWindow(
                    id: "bifrost-key-inactive",
                    title: "Key inactive",
                    window: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                    usageKnown: false),
                at: 0)
        }

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            extraRateWindows: allExtraWindows.isEmpty ? nil : allExtraWindows,
            providerCost: providerCost,
            details: details,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .bifrost,
                accountEmail: self.virtualKeyName,
                accountOrganization: providerCostBudget?.sourceName,
                loginMethod: "api"))
    }

    private static func budgetWindow(_ budget: Budget, now: Date) -> RateWindow? {
        let limit = budget.effectiveMaxLimit
        guard limit.isFinite, limit > 0, budget.currentUsage.isFinite else { return nil }
        let percent = UsagePercent(used: budget.currentUsage, limit: limit).displayClamped
        let parsed = BifrostResetDuration.parse(budget.resetDuration)
        return RateWindow(
            usedPercent: percent,
            windowMinutes: parsed?.windowMinutes,
            resetsAt: BifrostResetDuration.nextReset(
                lastReset: budget.lastReset,
                duration: budget.resetDuration,
                now: now),
            resetDescription: Self.resetDescription(
                sourceName: budget.sourceName,
                label: parsed?.label,
                used: budget.currentUsage,
                limit: limit))
    }

    private static func resetDescription(
        sourceName: String?,
        label: String?,
        used: Double,
        limit: Double) -> String
    {
        var segments: [String] = []
        if let sourceName = Self.nonEmpty(sourceName) {
            segments.append(String(sourceName.prefix(24)))
        }
        if let label {
            segments.append(label)
        }
        segments.append("\(UsageFormatter.usdString(used)) / \(UsageFormatter.usdString(limit))")
        return segments.joined(separator: " · ")
    }

    private func providerCostSnapshot(from budget: Budget) -> ProviderCostSnapshot? {
        guard budget.currentUsage.isFinite else { return nil }
        let limit = budget.effectiveMaxLimit
        guard limit.isFinite else { return nil }
        let parsed = BifrostResetDuration.parse(budget.resetDuration)
        return ProviderCostSnapshot(
            used: budget.currentUsage,
            limit: max(0, limit),
            currencyCode: "USD",
            period: parsed?.label ?? (limit > 0 ? "Budget" : "Spend"),
            resetsAt: BifrostResetDuration.nextReset(
                lastReset: budget.lastReset,
                duration: budget.resetDuration,
                now: self.updatedAt),
            updatedAt: self.updatedAt)
    }

    private func modelUsageSection(from budget: Budget) -> ProviderDetailSection? {
        guard !budget.perModelUsage.isEmpty else { return nil }
        let rows = budget.perModelUsage
            .sorted { ($0.totalCost ?? 0) > ($1.totalCost ?? 0) }
            .map { usage -> ProviderDetailSection.Row in
                let label = [usage.provider, usage.model].compactMap(\.self).joined(separator: " · ")
                let cost = usage.totalCost.map(UsageFormatter.usdString) ?? "—"
                let secondary: String? = usage.totalTokens.map { "\($0) tokens" }
                return ProviderDetailSection.Row.makeRow(
                    label: label.isEmpty ? "Model" : label,
                    value: cost,
                    secondaryValue: secondary,
                    usageValue: usage.totalCost)
            }
        return ProviderDetailSection.makeSection(title: "Models", rows: rows)
    }

    private func budgetsSection(_ budgets: [Budget]) -> ProviderDetailSection {
        let rows = budgets.map { budget -> ProviderDetailSection.Row in
            let label = budget.sourceName ?? "Budget \(budget.id)"
            let limit = budget.effectiveMaxLimit
            let value = limit > 0
                ? "\(UsageFormatter.usdString(budget.currentUsage)) / \(UsageFormatter.usdString(limit))"
                : UsageFormatter.usdString(budget.currentUsage)
            let secondary = BifrostResetDuration.parse(budget.resetDuration)?.label
            let progress: ProviderDetailSection.Row.Progress? =
                (limit.isFinite && limit > 0 && budget.currentUsage.isFinite)
                ? .makeProgress(used: budget.currentUsage, total: limit)
                : nil
            return ProviderDetailSection.Row.makeRow(
                label: label,
                value: value,
                secondaryValue: secondary,
                progress: progress,
                usageValue: budget.currentUsage)
        }
        return ProviderDetailSection.makeSection(title: "Budgets", rows: rows)
    }

    private func rateLimitNamedWindows() -> [NamedRateWindow] {
        guard let primary = self.rateLimits.first else { return [] }
        var seenIDs = Set<String>()
        if let id = primary.id { seenIDs.insert(id) }

        var windows = Self.namedWindows(for: primary, titlePrefix: nil, idSuffix: "", now: self.updatedAt)
        for extra in self.rateLimits.dropFirst() {
            if let id = extra.id, seenIDs.contains(id) { continue }
            if let id = extra.id { seenIDs.insert(id) }
            let suffix = extra.id.map { "-\($0)" } ?? "-\(windows.count)"
            windows += Self.namedWindows(
                for: extra,
                titlePrefix: extra.sourceName,
                idSuffix: suffix,
                now: self.updatedAt)
        }
        return windows
    }

    private static func namedWindows(
        for limit: RateLimit,
        titlePrefix: String?,
        idSuffix: String,
        now: Date) -> [NamedRateWindow]
    {
        var windows: [NamedRateWindow] = []
        if let window = Self.namedWindow(
            id: "bifrost-tokens\(idSuffix)",
            title: [titlePrefix, "Tokens"].compactMap(\.self).joined(separator: " "),
            side: RateLimitSide(
                maxLimit: limit.tokenMaxLimit,
                currentUsage: limit.tokenCurrentUsage,
                resetDuration: limit.tokenResetDuration,
                lastReset: limit.tokenLastReset),
            now: now)
        {
            windows.append(window)
        }
        if let window = Self.namedWindow(
            id: "bifrost-requests\(idSuffix)",
            title: [titlePrefix, "Requests"].compactMap(\.self).joined(separator: " "),
            side: RateLimitSide(
                maxLimit: limit.requestMaxLimit,
                currentUsage: limit.requestCurrentUsage,
                resetDuration: limit.requestResetDuration,
                lastReset: limit.requestLastReset),
            now: now)
        {
            windows.append(window)
        }
        return windows
    }

    private struct RateLimitSide {
        let maxLimit: Double?
        let currentUsage: Double
        let resetDuration: String?
        let lastReset: Date?
    }

    private static func namedWindow(
        id: String,
        title: String,
        side: RateLimitSide,
        now: Date) -> NamedRateWindow?
    {
        let parsed = BifrostResetDuration.parse(side.resetDuration)
        let resetsAt = BifrostResetDuration.nextReset(
            lastReset: side.lastReset,
            duration: side.resetDuration,
            now: now)

        if let maxLimit = side.maxLimit, maxLimit.isFinite, maxLimit > 0, side.currentUsage.isFinite {
            let percent = UsagePercent(used: side.currentUsage, limit: maxLimit).displayClamped
            return NamedRateWindow(
                id: id,
                title: title,
                window: RateWindow(
                    usedPercent: percent,
                    windowMinutes: parsed?.windowMinutes,
                    resetsAt: resetsAt,
                    resetDescription: parsed?.label))
        }
        guard side.resetDuration != nil || side.lastReset != nil else { return nil }
        return NamedRateWindow(
            id: id,
            title: title,
            window: RateWindow(
                usedPercent: 0,
                windowMinutes: parsed?.windowMinutes,
                resetsAt: resetsAt,
                resetDescription: parsed?.label),
            usageKnown: false)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private struct BifrostQuotaResponse: Decodable {
    struct ModelUsage: Decodable {
        let model: String?
        let provider: String?
        let totalRequests: Double?
        let totalTokens: Double?
        let totalCost: Double?

        private enum CodingKeys: String, CodingKey {
            case model
            case provider
            case totalRequests = "total_requests"
            case totalTokens = "total_tokens"
            case totalCost = "total_cost"
        }
    }

    struct Budget: Decodable {
        let id: String?
        let maxLimit: Double?
        let resetDuration: String?
        let lastReset: String?
        let currentUsage: Double?
        let overrideAmount: Double?
        let overrideMode: String?
        let overrideCyclesRemaining: Int?
        let sourceName: String?
        let perModelUsage: [ModelUsage]?

        private enum CodingKeys: String, CodingKey {
            case id
            case maxLimit = "max_limit"
            case resetDuration = "reset_duration"
            case lastReset = "last_reset"
            case currentUsage = "current_usage"
            case overrideAmount = "override_amount"
            case overrideMode = "override_mode"
            case overrideCyclesRemaining = "override_cycles_remaining"
            case sourceName = "source_name"
            case perModelUsage = "per_model_usage"
        }
    }

    struct RateLimit: Decodable {
        let id: String?
        let sourceName: String?
        let tokenMaxLimit: Double?
        let tokenCurrentUsage: Double?
        let tokenResetDuration: String?
        let tokenLastReset: String?
        let requestMaxLimit: Double?
        let requestCurrentUsage: Double?
        let requestResetDuration: String?
        let requestLastReset: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case sourceName = "source_name"
            case tokenMaxLimit = "token_max_limit"
            case tokenCurrentUsage = "token_current_usage"
            case tokenResetDuration = "token_reset_duration"
            case tokenLastReset = "token_last_reset"
            case requestMaxLimit = "request_max_limit"
            case requestCurrentUsage = "request_current_usage"
            case requestResetDuration = "request_reset_duration"
            case requestLastReset = "request_last_reset"
        }
    }

    let virtualKeyName: String?
    let isActive: Bool?
    let budgets: [Budget]?
    let rateLimit: RateLimit?
    let rateLimits: [RateLimit]?

    private enum CodingKeys: String, CodingKey {
        case virtualKeyName = "virtual_key_name"
        case isActive = "is_active"
        case budgets
        case rateLimit = "rate_limit"
        case rateLimits = "rate_limits"
    }
}

public struct BifrostUsageFetcher: Sendable {
    public init() {}

    public static func fetchUsage(
        apiKey: String,
        baseURL: URL,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        updatedAt: Date = Date()) async throws -> BifrostUsageSnapshot
    {
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else {
            throw BifrostUsageError.missingCredentials
        }
        let request = self.request(url: self.quotaURL(baseURL: baseURL), apiKey: cleanedKey)
        let response = try await transport.response(for: request)
        switch response.statusCode {
        case 200..<300:
            break
        case 401:
            throw BifrostUsageError.unauthorized
        case 403:
            throw BifrostUsageError.keyExpired
        default:
            throw BifrostUsageError.apiError("HTTP \(response.statusCode): \(Self.responseSummary(response.data))")
        }
        return try self.parseQuota(response.data, updatedAt: updatedAt)
    }

    public static func _parseQuotaForTesting(_ data: Data, updatedAt: Date) throws -> BifrostUsageSnapshot {
        try self.parseQuota(data, updatedAt: updatedAt)
    }

    public static func _quotaURLForTesting(baseURL: URL) -> URL {
        self.quotaURL(baseURL: baseURL)
    }

    private static func request(url: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // The virtual key is its own credential on this self-service endpoint. `x-bf-vk` is accepted
        // verbatim, unlike the Authorization/x-api-key fallbacks that require an `sk-bf-` prefix.
        request.setValue(apiKey, forHTTPHeaderField: "x-bf-vk")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func quotaURL(baseURL: URL) -> URL {
        baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("governance")
            .appendingPathComponent("virtual-keys")
            .appendingPathComponent("quota")
    }

    private static func parseQuota(_ data: Data, updatedAt: Date) throws -> BifrostUsageSnapshot {
        do {
            let decoded = try JSONDecoder().decode(BifrostQuotaResponse.self, from: data)
            let budgets = (decoded.budgets ?? []).compactMap(self.mapBudget)
            let rateLimits = ([decoded.rateLimit].compactMap(\.self) + (decoded.rateLimits ?? []))
                .compactMap(self.mapRateLimit)
            let isActive = decoded.isActive ?? true
            guard isActive || !budgets.isEmpty || !rateLimits.isEmpty else {
                throw BifrostUsageError.inactiveKey
            }
            return BifrostUsageSnapshot(
                virtualKeyName: self.nonEmpty(decoded.virtualKeyName),
                isActive: isActive,
                budgets: budgets,
                rateLimits: rateLimits,
                updatedAt: updatedAt)
        } catch let error as BifrostUsageError {
            throw error
        } catch {
            throw BifrostUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func mapBudget(_ wire: BifrostQuotaResponse.Budget) -> BifrostUsageSnapshot.Budget? {
        guard let id = self.nonEmpty(wire.id) else { return nil }
        return BifrostUsageSnapshot.Budget(
            id: id,
            maxLimit: wire.maxLimit ?? 0,
            resetDuration: wire.resetDuration,
            lastReset: ISO8601DateParser.parse(wire.lastReset),
            currentUsage: wire.currentUsage ?? 0,
            overrideAmount: wire.overrideAmount ?? 0,
            overrideMode: wire.overrideMode,
            overrideCyclesRemaining: wire.overrideCyclesRemaining,
            sourceName: self.nonEmpty(wire.sourceName),
            perModelUsage: (wire.perModelUsage ?? []).map { usage in
                BifrostUsageSnapshot.ModelUsage(
                    model: self.nonEmpty(usage.model),
                    provider: self.nonEmpty(usage.provider),
                    totalRequests: self.boundedInt(usage.totalRequests),
                    totalTokens: self.boundedInt(usage.totalTokens),
                    totalCost: usage.totalCost)
            })
    }

    private static func mapRateLimit(_ wire: BifrostQuotaResponse.RateLimit) -> BifrostUsageSnapshot.RateLimit {
        BifrostUsageSnapshot.RateLimit(
            id: self.nonEmpty(wire.id),
            sourceName: self.nonEmpty(wire.sourceName),
            tokenMaxLimit: wire.tokenMaxLimit,
            tokenCurrentUsage: wire.tokenCurrentUsage ?? 0,
            tokenResetDuration: wire.tokenResetDuration,
            tokenLastReset: ISO8601DateParser.parse(wire.tokenLastReset),
            requestMaxLimit: wire.requestMaxLimit,
            requestCurrentUsage: wire.requestCurrentUsage ?? 0,
            requestResetDuration: wire.requestResetDuration,
            requestLastReset: ISO8601DateParser.parse(wire.requestLastReset))
    }

    /// Failable integer conversion: a value outside `Int`'s exact range is dropped rather than
    /// truncated, since comparing against `Double(Int.max)` would round upward past the true boundary.
    private static func boundedInt(_ value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        return Int(exactly: value.rounded(.towardZero))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func responseSummary(_ data: Data) -> String {
        String(bytes: data.prefix(500), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }
}
