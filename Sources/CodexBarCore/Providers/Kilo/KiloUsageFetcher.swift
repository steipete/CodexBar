import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct KiloUsageSnapshot: Sendable {
    public let creditsUsed: Double?
    public let creditsTotal: Double?
    public let creditsRemaining: Double?
    public let passUsed: Double?
    public let passTotal: Double?
    public let passRemaining: Double?
    public let passBonus: Double?
    public let passResetsAt: Date?
    public let planName: String?
    public let autoTopUpEnabled: Bool?
    public let autoTopUpMethod: String?
    public let updatedAt: Date

    public init(
        creditsUsed: Double?,
        creditsTotal: Double?,
        creditsRemaining: Double?,
        passUsed: Double? = nil,
        passTotal: Double? = nil,
        passRemaining: Double? = nil,
        passBonus: Double? = nil,
        passResetsAt: Date? = nil,
        planName: String?,
        autoTopUpEnabled: Bool?,
        autoTopUpMethod: String?,
        updatedAt: Date)
    {
        self.creditsUsed = creditsUsed
        self.creditsTotal = creditsTotal
        self.creditsRemaining = creditsRemaining
        self.passUsed = passUsed
        self.passTotal = passTotal
        self.passRemaining = passRemaining
        self.passBonus = passBonus
        self.passResetsAt = passResetsAt
        self.planName = planName
        self.autoTopUpEnabled = autoTopUpEnabled
        self.autoTopUpMethod = autoTopUpMethod
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let total = self.resolvedTotal
        let used = self.resolvedUsed

        let primary: RateWindow?
        if let total {
            let usedPercent: Double = if total > 0 {
                min(100, max(0, (used / total) * 100))
            } else {
                // Preserve a visible exhausted state for valid zero-total snapshots.
                100
            }
            let usedText = Self.compactNumber(used)
            let totalText = Self.compactNumber(total)
            primary = RateWindow(
                usedPercent: usedPercent,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "\(usedText)/\(totalText) credits")
        } else {
            primary = nil
        }

        let loginMethod = Self.makeLoginMethod(
            planName: self.planName,
            autoTopUpEnabled: self.autoTopUpEnabled,
            autoTopUpMethod: self.autoTopUpMethod)

        return UsageSnapshot(
            primary: primary,
            secondary: self.passWindow,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .kilo,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: loginMethod))
    }

    private var resolvedTotal: Double? {
        if let creditsTotal { return max(0, creditsTotal) }
        if let creditsUsed, let creditsRemaining {
            return max(0, creditsUsed + creditsRemaining)
        }
        return nil
    }

    private var resolvedUsed: Double {
        if let creditsUsed {
            return max(0, creditsUsed)
        }
        if let total = self.resolvedTotal,
           let creditsRemaining
        {
            return max(0, total - creditsRemaining)
        }
        return 0
    }

    private var resolvedPassTotal: Double? {
        if let passTotal { return max(0, passTotal) }
        if let passUsed, let passRemaining {
            return max(0, passUsed + passRemaining)
        }
        return nil
    }

    private var resolvedPassUsed: Double {
        if let passUsed {
            return max(0, passUsed)
        }
        if let total = self.resolvedPassTotal,
           let passRemaining
        {
            return max(0, total - passRemaining)
        }
        return 0
    }

    private var passWindow: RateWindow? {
        guard let total = self.resolvedPassTotal else {
            return nil
        }

        let used = self.resolvedPassUsed
        let bonus = max(0, self.passBonus ?? 0)
        let baseCredits = max(0, total - bonus)
        let usedPercent: Double = if total > 0 {
            min(100, max(0, (used / total) * 100))
        } else {
            100
        }

        var detail = "$\(Self.currencyNumber(used)) / $\(Self.currencyNumber(baseCredits))"
        if bonus > 0 {
            detail += " (+ $\(Self.currencyNumber(bonus)) bonus)"
        }

        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: self.passResetsAt,
            resetDescription: detail)
    }

    private static func compactNumber(_ value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    private static func currencyNumber(_ value: Double) -> String {
        String(format: "%.2f", max(0, value))
    }

    private static func makeLoginMethod(
        planName: String?,
        autoTopUpEnabled: Bool?,
        autoTopUpMethod: String?) -> String?
    {
        var parts: [String] = []

        if let planName = Self.trimmed(planName) {
            parts.append(planName)
        }

        if let autoTopUpEnabled {
            if autoTopUpEnabled {
                if let method = Self.trimmed(autoTopUpMethod) {
                    parts.append("Auto top-up: \(method)")
                } else {
                    parts.append("Auto top-up: enabled")
                }
            } else {
                parts.append("Auto top-up: off")
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func trimmed(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum KiloUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case cliSessionMissing(String)
    case cliSessionUnreadable(String)
    case cliSessionInvalid(String)
    case unauthorized
    case endpointNotFound
    case serviceUnavailable(Int)
    case networkError(String)
    case parseFailed(String)
    case apiError(Int)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Kilo API credentials missing. Set KILO_API_KEY."
        case let .cliSessionMissing(path):
            "Kilo CLI session not found at \(path). Run `kilo login` to create ~/.local/share/kilo/auth.json."
        case let .cliSessionUnreadable(path):
            "Kilo CLI session file is unreadable at \(path). Fix permissions or run `kilo login` again."
        case let .cliSessionInvalid(path):
            "Kilo CLI session file is invalid at \(path). Run `kilo login` to refresh auth.json."
        case .unauthorized:
            "Kilo authentication failed (401/403). Refresh KILO_API_KEY or run `kilo login`."
        case .endpointNotFound:
            "Kilo API endpoint not found (404). Verify the tRPC batch path and procedure names."
        case let .serviceUnavailable(statusCode):
            "Kilo API is currently unavailable (HTTP \(statusCode)). Try again later."
        case let .networkError(message):
            "Kilo network error: \(message)"
        case .parseFailed:
            "Failed to parse Kilo API response. Response format may have changed."
        case let .apiError(statusCode):
            "Kilo API request failed (HTTP \(statusCode))."
        }
    }
}

public struct KiloUsageFetcher: Sendable {
    private struct KiloPassFields {
        let used: Double?
        let total: Double?
        let remaining: Double?
        let bonus: Double?
        let resetsAt: Date?
    }

    static let procedures = [
        "user.getCreditBlocks",
        "kiloPass.getState",
        "user.getAutoTopUpPaymentMethod",
    ]

    private static let optionalProcedures: Set<String> = [
        "user.getAutoTopUpPaymentMethod",
    ]

    private static let maxTopLevelEntries = procedures.count

    public static func fetchUsage(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> KiloUsageSnapshot
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KiloUsageError.missingCredentials
        }

        let baseURL = KiloSettingsReader.apiURL(environment: environment)
        let batchURL = try self.makeBatchURL(baseURL: baseURL)

        var request = URLRequest(url: batchURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw KiloUsageError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw KiloUsageError.networkError("Invalid response")
        }

        if let mapped = self.statusError(for: httpResponse.statusCode) {
            throw mapped
        }

        guard httpResponse.statusCode == 200 else {
            throw KiloUsageError.apiError(httpResponse.statusCode)
        }

        return try self.parseSnapshot(data: data)
    }

    static func _buildBatchURLForTesting(baseURL: URL) throws -> URL {
        try self.makeBatchURL(baseURL: baseURL)
    }

    static func _parseSnapshotForTesting(_ data: Data) throws -> KiloUsageSnapshot {
        try self.parseSnapshot(data: data)
    }

    static func _statusErrorForTesting(_ statusCode: Int) -> KiloUsageError? {
        self.statusError(for: statusCode)
    }

    private static func statusError(for statusCode: Int) -> KiloUsageError? {
        switch statusCode {
        case 401, 403:
            .unauthorized
        case 404:
            .endpointNotFound
        case 500...599:
            .serviceUnavailable(statusCode)
        default:
            nil
        }
    }

    private static func makeBatchURL(baseURL: URL) throws -> URL {
        let joinedProcedures = self.procedures.joined(separator: ",")
        let endpoint = baseURL.appendingPathComponent(joinedProcedures)

        let inputMap = Dictionary(uniqueKeysWithValues: self.procedures.indices.map {
            (String($0), ["json": NSNull()])
        })
        let inputData = try JSONSerialization.data(withJSONObject: inputMap)
        guard let inputString = String(data: inputData, encoding: .utf8) else {
            throw KiloUsageError.parseFailed("Invalid batch input")
        }

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw KiloUsageError.parseFailed("Invalid batch endpoint")
        }
        components.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: inputString),
        ]

        guard let url = components.url else {
            throw KiloUsageError.parseFailed("Invalid batch endpoint")
        }
        return url
    }

    private static func parseSnapshot(data: Data) throws -> KiloUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw KiloUsageError.parseFailed("Invalid JSON")
        }

        let entriesByIndex = try self.responseEntriesByIndex(from: root)
        var payloadsByProcedure: [String: Any] = [:]

        for (index, procedure) in self.procedures.enumerated() {
            guard let entry = entriesByIndex[index] else { continue }
            if let mappedError = self.trpcError(from: entry) {
                guard self.isRequiredProcedure(procedure) else {
                    continue
                }
                throw mappedError
            }
            if let payload = self.resultPayload(from: entry) {
                payloadsByProcedure[procedure] = payload
            }
        }

        let creditFields = self.creditFields(from: payloadsByProcedure[self.procedures[0]])
        let passFields = self.passFields(from: payloadsByProcedure[self.procedures[1]])
        let planName = self.planName(from: payloadsByProcedure[self.procedures[1]])
        let autoTopUp = self.autoTopUpState(
            creditBlocksPayload: payloadsByProcedure[self.procedures[0]],
            autoTopUpPayload: payloadsByProcedure[self.procedures[2]])

        return KiloUsageSnapshot(
            creditsUsed: creditFields.used,
            creditsTotal: creditFields.total,
            creditsRemaining: creditFields.remaining,
            passUsed: passFields.used,
            passTotal: passFields.total,
            passRemaining: passFields.remaining,
            passBonus: passFields.bonus,
            passResetsAt: passFields.resetsAt,
            planName: planName,
            autoTopUpEnabled: autoTopUp.enabled,
            autoTopUpMethod: autoTopUp.method,
            updatedAt: Date())
    }

    private static func isRequiredProcedure(_ procedure: String) -> Bool {
        !self.optionalProcedures.contains(procedure)
    }

    private static func responseEntriesByIndex(from root: Any) throws -> [Int: [String: Any]] {
        if let entries = root as? [[String: Any]] {
            let limited = Array(entries.prefix(self.maxTopLevelEntries))
            return Dictionary(uniqueKeysWithValues: limited.enumerated().map { ($0.offset, $0.element) })
        }

        if let dictionary = root as? [String: Any] {
            if dictionary["result"] != nil || dictionary["error"] != nil {
                return [0: dictionary]
            }

            let indexedEntries = dictionary
                .compactMap { key, value -> (Int, [String: Any])? in
                    guard let index = Int(key),
                          let entry = value as? [String: Any]
                    else {
                        return nil
                    }
                    return (index, entry)
                }
            if !indexedEntries.isEmpty {
                let limitedEntries = indexedEntries.filter { $0.0 >= 0 && $0.0 < self.maxTopLevelEntries }
                return Dictionary(uniqueKeysWithValues: limitedEntries)
            }
        }

        throw KiloUsageError.parseFailed("Unexpected tRPC batch shape")
    }

    private static func trpcError(from entry: [String: Any]) -> KiloUsageError? {
        guard let errorObject = entry["error"] as? [String: Any] else { return nil }

        let code = self.stringValue(for: ["json", "data", "code"], in: errorObject)
            ?? self.stringValue(for: ["data", "code"], in: errorObject)
            ?? self.stringValue(for: ["code"], in: errorObject)
        let message = self.stringValue(for: ["json", "message"], in: errorObject)
            ?? self.stringValue(for: ["message"], in: errorObject)

        let combined = [code, message]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if combined.contains("unauthorized") || combined.contains("forbidden") {
            return .unauthorized
        }

        if combined.contains("not_found") || combined.contains("not found") {
            return .endpointNotFound
        }

        return .parseFailed("tRPC error payload")
    }

    private static func resultPayload(from entry: [String: Any]) -> Any? {
        guard let resultObject = entry["result"] as? [String: Any] else { return nil }

        if let dataObject = resultObject["data"] as? [String: Any] {
            if let jsonPayload = dataObject["json"] {
                if jsonPayload is NSNull { return nil }
                return jsonPayload
            }
            return dataObject
        }

        if let jsonPayload = resultObject["json"] {
            if jsonPayload is NSNull { return nil }
            return jsonPayload
        }

        return nil
    }

    private static func creditFields(from payload: Any?) -> (used: Double?, total: Double?, remaining: Double?) {
        guard let payload else { return (nil, nil, nil) }

        let contexts = self.dictionaryContexts(from: payload)
        let blocks = self.firstArray(forKeys: ["creditBlocks"], in: contexts)

        if let blocks {
            var totalFromBlocks: Double = 0
            var remainingFromBlocks: Double = 0
            var sawTotal = false
            var sawRemaining = false

            for case let block as [String: Any] in blocks {
                if let amountMicroUSD = self.double(from: block["amount_mUsd"]) {
                    totalFromBlocks += amountMicroUSD / 1_000_000
                    sawTotal = true
                }
                if let balanceMicroUSD = self.double(from: block["balance_mUsd"]) {
                    remainingFromBlocks += balanceMicroUSD / 1_000_000
                    sawRemaining = true
                }
            }

            if sawTotal || sawRemaining {
                let total = sawTotal ? max(0, totalFromBlocks) : nil
                let remaining = sawRemaining ? max(0, remainingFromBlocks) : nil
                let used: Double? = if let total, let remaining {
                    max(0, total - remaining)
                } else {
                    nil
                }
                return (used, total, remaining)
            }
        }

        let genericBlocks = self.firstArray(forKeys: ["blocks"], in: contexts)
        let blockContexts = (genericBlocks ?? []).compactMap { $0 as? [String: Any] }

        var used = self.firstDouble(
            forKeys: ["used", "usedCredits", "consumed", "spent", "creditsUsed"],
            in: blockContexts)
        var total = self.firstDouble(forKeys: ["total", "totalCredits", "creditsTotal", "limit"], in: blockContexts)
        var remaining = self.firstDouble(
            forKeys: ["remaining", "remainingCredits", "creditsRemaining"],
            in: blockContexts)

        if used == nil {
            used = self.firstDouble(
                forKeys: ["used", "usedCredits", "creditsUsed", "consumed", "spent"],
                in: contexts)
        }
        if total == nil {
            total = self.firstDouble(forKeys: ["total", "totalCredits", "creditsTotal", "limit"], in: contexts)
        }
        if remaining == nil {
            remaining = self.firstDouble(
                forKeys: ["remaining", "remainingCredits", "creditsRemaining"],
                in: contexts)
        }

        if total == nil,
           let used,
           let remaining
        {
            total = used + remaining
        }

        if used == nil, total == nil, remaining == nil,
           let balanceMilliUSD = self.firstDouble(forKeys: ["totalBalance_mUsd"], in: contexts),
           balanceMilliUSD == 0
        {
            // Kilo may return an empty creditBlocks list for zero-balance accounts.
            // Keep this visible as an explicit exhausted edge state instead of "no data".
            return (0, 0, 0)
        }

        if used == nil,
           total == nil,
           remaining == nil,
           let balanceMilliUSD = self.firstDouble(forKeys: ["totalBalance_mUsd"], in: contexts)
        {
            let balance = max(0, balanceMilliUSD / 1_000_000)
            return (max(0, 0), balance, balance)
        }

        return (used, total, remaining)
    }

    private static func passFields(from payload: Any?) -> KiloPassFields {
        if let subscription = self.subscriptionData(from: payload) {
            let used = self.double(from: subscription["currentPeriodUsageUsd"]).map { max(0, $0) }
            let baseCredits = self.double(from: subscription["currentPeriodBaseCreditsUsd"]).map { max(0, $0) }
            let bonusCredits = max(0, self.double(from: subscription["currentPeriodBonusCreditsUsd"]) ?? 0)
            let total = baseCredits.map { $0 + bonusCredits }
            let remaining: Double? = if let total, let used {
                max(0, total - used)
            } else {
                nil
            }
            let resetsAt = self.date(from: subscription["nextBillingAt"])
                ?? self.date(from: subscription["nextRenewalAt"])
                ?? self.date(from: subscription["renewsAt"])
                ?? self.date(from: subscription["renewAt"])

            return KiloPassFields(
                used: used,
                total: total,
                remaining: remaining,
                bonus: bonusCredits > 0 ? bonusCredits : nil,
                resetsAt: resetsAt)
        }

        return self.fallbackPassFields(from: payload)
    }

    private static func fallbackPassFields(from payload: Any?) -> KiloPassFields {
        let contexts = self.dictionaryContexts(from: payload)
        guard !contexts.isEmpty else {
            return KiloPassFields(used: nil, total: nil, remaining: nil, bonus: nil, resetsAt: nil)
        }

        var total = self.moneyAmount(
            centsKeys: [
                "amountCents",
                "totalCents",
                "planAmountCents",
                "monthlyAmountCents",
                "limitCents",
                "includedCents",
                "valueCents",
            ],
            milliUSDKeys: [
                "amount_mUsd",
                "total_mUsd",
                "planAmount_mUsd",
                "limit_mUsd",
                "included_mUsd",
                "value_mUsd",
            ],
            plainKeys: [
                "amount",
                "total",
                "limit",
                "included",
                "value",
                "creditsTotal",
                "totalCredits",
                "planAmount",
            ],
            in: contexts)
        var used = self.moneyAmount(
            centsKeys: [
                "usedCents",
                "spentCents",
                "consumedCents",
                "usedAmountCents",
                "consumedAmountCents",
            ],
            milliUSDKeys: [
                "used_mUsd",
                "spent_mUsd",
                "consumed_mUsd",
                "usedAmount_mUsd",
            ],
            plainKeys: [
                "used",
                "spent",
                "consumed",
                "usage",
                "creditsUsed",
                "usedAmount",
                "consumedAmount",
            ],
            in: contexts)
        var remaining = self.moneyAmount(
            centsKeys: [
                "remainingCents",
                "remainingAmountCents",
                "availableCents",
                "leftCents",
                "balanceCents",
            ],
            milliUSDKeys: [
                "remaining_mUsd",
                "available_mUsd",
                "left_mUsd",
                "balance_mUsd",
            ],
            plainKeys: [
                "remaining",
                "available",
                "left",
                "balance",
                "creditsRemaining",
                "remainingAmount",
                "availableAmount",
            ],
            in: contexts)
        let bonus = self.moneyAmount(
            centsKeys: [
                "bonusCents",
                "bonusAmountCents",
                "includedBonusCents",
                "bonusRemainingCents",
            ],
            milliUSDKeys: [
                "bonus_mUsd",
                "bonusAmount_mUsd",
            ],
            plainKeys: [
                "bonus",
                "bonusAmount",
                "bonusCredits",
                "includedBonus",
            ],
            in: contexts)
        let resetsAt = self.firstDate(
            forKeys: [
                "resetAt",
                "resetsAt",
                "nextResetAt",
                "renewAt",
                "renewsAt",
                "nextRenewalAt",
                "currentPeriodEnd",
                "periodEndsAt",
                "expiresAt",
                "expiryAt",
            ],
            in: contexts)

        if total == nil,
           let used,
           let remaining
        {
            total = used + remaining
        }
        if used == nil,
           let total,
           let remaining
        {
            used = max(0, total - remaining)
        }
        if remaining == nil,
           let total,
           let used
        {
            remaining = max(0, total - used)
        }

        return KiloPassFields(
            used: used,
            total: total,
            remaining: remaining,
            bonus: bonus,
            resetsAt: resetsAt)
    }

    private static func planName(from payload: Any?) -> String? {
        if let subscription = self.subscriptionData(from: payload) {
            if let tier = self.string(from: subscription["tier"]) {
                let trimmed = tier.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return self.planNameForTier(trimmed)
                }
            }
            return "Kilo Pass"
        }

        let contexts = self.dictionaryContexts(from: payload)
        let candidates = [
            self.firstString(
                forKeys: ["planName", "tier", "tierName", "passName", "subscriptionName"],
                in: contexts),
            self.stringValue(for: ["plan", "name"], in: contexts),
            self.stringValue(for: ["subscription", "plan", "name"], in: contexts),
            self.stringValue(for: ["subscription", "name"], in: contexts),
            self.stringValue(for: ["pass", "name"], in: contexts),
            self.stringValue(for: ["state", "name"], in: contexts),
            self.stringValue(for: ["state"], in: contexts),
        ]

        for candidate in candidates {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                continue
            }
            return trimmed
        }
        if let fallback = self.firstString(forKeys: ["name"], in: contexts),
           fallback.lowercased().contains("pass")
        {
            return fallback
        }
        return nil
    }

    private static func autoTopUpState(
        creditBlocksPayload: Any?,
        autoTopUpPayload: Any?) -> (enabled: Bool?, method: String?)
    {
        let creditContexts = self.dictionaryContexts(from: creditBlocksPayload)
        let autoTopUpContexts = self.dictionaryContexts(from: autoTopUpPayload)
        let enabled = self.firstBool(forKeys: ["enabled", "isEnabled", "active"], in: autoTopUpContexts)
            ?? self.boolFromStatusString(self.firstString(forKeys: ["status"], in: autoTopUpContexts))
            ?? self.firstBool(forKeys: ["autoTopUpEnabled"], in: creditContexts)

        let rawMethod = self.firstString(
            forKeys: ["paymentMethod", "paymentMethodType", "method", "cardBrand"],
            in: autoTopUpContexts)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let amount = self.moneyAmount(
            centsKeys: ["amountCents"],
            milliUSDKeys: [],
            plainKeys: ["amount", "topUpAmount", "amountUsd"],
            in: autoTopUpContexts)

        let method: String? = if let rawMethod, !rawMethod.isEmpty {
            rawMethod
        } else if let amount, amount > 0 {
            self.currencyAmountLabel(amount)
        } else {
            nil
        }

        return (enabled, method)
    }

    private static func subscriptionData(from payload: Any?) -> [String: Any]? {
        guard let payloadDictionary = payload as? [String: Any] else {
            return nil
        }

        if let subscription = payloadDictionary["subscription"] as? [String: Any] {
            return subscription
        }

        if payloadDictionary["subscription"] is NSNull {
            return nil
        }

        let hasSubscriptionShape = payloadDictionary["currentPeriodUsageUsd"] != nil ||
            payloadDictionary["currentPeriodBaseCreditsUsd"] != nil ||
            payloadDictionary["currentPeriodBonusCreditsUsd"] != nil ||
            payloadDictionary["tier"] != nil
        return hasSubscriptionShape ? payloadDictionary : nil
    }

    private static func planNameForTier(_ tier: String) -> String {
        switch tier {
        case "tier_19":
            "Starter"
        case "tier_49":
            "Pro"
        case "tier_199":
            "Expert"
        default:
            tier
        }
    }

    private static func string(from raw: Any?) -> String? {
        if let value = raw as? String {
            return value
        }
        return nil
    }

    private static func dictionaryContexts(from payload: Any?) -> [[String: Any]] {
        guard let payload else { return [] }
        guard let dictionary = payload as? [String: Any] else { return [] }

        var contexts: [[String: Any]] = []
        var queue: [([String: Any], Int)] = [(dictionary, 0)]
        let maxDepth = 2

        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()
            contexts.append(current)

            guard depth < maxDepth else {
                continue
            }

            for value in current.values {
                if let nested = value as? [String: Any] {
                    queue.append((nested, depth + 1))
                    continue
                }
                if let nestedArray = value as? [Any] {
                    for case let nested as [String: Any] in nestedArray {
                        queue.append((nested, depth + 1))
                    }
                }
            }
        }

        return contexts
    }

    private static func firstArray(forKeys keys: [String], in contexts: [[String: Any]]) -> [Any]? {
        for context in contexts {
            for key in keys {
                if let values = context[key] as? [Any] {
                    return values
                }
            }
        }
        return nil
    }

    private static func firstDouble(forKeys keys: [String], in contexts: [[String: Any]]) -> Double? {
        for context in contexts {
            for key in keys {
                if let value = self.double(from: context[key]) {
                    return value
                }
            }
        }
        return nil
    }

    private static func firstString(forKeys keys: [String], in contexts: [[String: Any]]) -> String? {
        for context in contexts {
            for key in keys {
                if let value = context[key] as? String {
                    return value
                }
            }
        }
        return nil
    }

    private static func firstBool(forKeys keys: [String], in contexts: [[String: Any]]) -> Bool? {
        for context in contexts {
            for key in keys {
                if let value = self.bool(from: context[key]) {
                    return value
                }
            }
        }
        return nil
    }

    private static func firstDate(forKeys keys: [String], in contexts: [[String: Any]]) -> Date? {
        for context in contexts {
            for key in keys {
                if let value = self.date(from: context[key]) {
                    return value
                }
            }
        }
        return nil
    }

    private static func moneyAmount(
        centsKeys: [String],
        milliUSDKeys: [String],
        plainKeys: [String],
        in contexts: [[String: Any]]) -> Double?
    {
        if let cents = self.firstDouble(forKeys: centsKeys, in: contexts) {
            return cents / 100
        }
        if let milliUSD = self.firstDouble(forKeys: milliUSDKeys, in: contexts) {
            return milliUSD / 1_000_000
        }
        return self.firstDouble(forKeys: plainKeys, in: contexts)
    }

    private static func currencyAmountLabel(_ amount: Double) -> String {
        if amount.rounded(.towardZero) == amount {
            return String(format: "$%.0f", amount)
        }
        return String(format: "$%.2f", amount)
    }

    private static func stringValue(for path: [String], in dictionary: [String: Any]) -> String? {
        var cursor: Any = dictionary
        for key in path {
            guard let next = (cursor as? [String: Any])?[key] else {
                return nil
            }
            cursor = next
        }
        return cursor as? String
    }

    private static func stringValue(for path: [String], in contexts: [[String: Any]]) -> String? {
        for context in contexts {
            if let value = self.stringValue(for: path, in: context) {
                return value
            }
        }
        return nil
    }

    private static func boolFromStatusString(_ status: String?) -> Bool? {
        guard let status = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !status.isEmpty
        else {
            return nil
        }

        switch status {
        case "enabled", "active", "on":
            return true
        case "disabled", "inactive", "off", "none":
            return false
        default:
            return nil
        }
    }

    private static func double(from raw: Any?) -> Double? {
        switch raw {
        case let value as Double:
            value
        case let value as Int:
            Double(value)
        case let value as NSNumber:
            value.doubleValue
        case let value as String:
            Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func date(from raw: Any?) -> Date? {
        switch raw {
        case let value as Date:
            return value
        case let value as Double:
            return self.dateFromEpoch(value)
        case let value as Int:
            return self.dateFromEpoch(Double(value))
        case let value as NSNumber:
            return self.dateFromEpoch(value.doubleValue)
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let numeric = Double(trimmed) {
                return self.dateFromEpoch(numeric)
            }

            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = withFractional.date(from: trimmed) {
                return parsed
            }

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: trimmed)
        default:
            return nil
        }
    }

    private static func dateFromEpoch(_ value: Double) -> Date {
        let seconds = abs(value) > 10_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func bool(from raw: Any?) -> Bool? {
        switch raw {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "enabled", "on"].contains(normalized) {
                return true
            }
            if ["false", "0", "no", "disabled", "off"].contains(normalized) {
                return false
            }
            return nil
        default:
            return nil
        }
    }
}
