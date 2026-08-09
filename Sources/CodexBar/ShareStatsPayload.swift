import CodexBarCore
import Foundation

struct ShareStatsProviderPayload: Sendable, Equatable {
    let sourceID: String?
    let provider: UsageProvider
    let providerName: String
    let subscriptionName: String?
    let currencyCode: String
    let totalTokens: Int?
    let estimatedCost: Double?
    let coveredDayCount: Int

    init(
        sourceID: String? = nil,
        provider: UsageProvider,
        providerName: String,
        subscriptionName: String?,
        currencyCode: String,
        totalTokens: Int?,
        estimatedCost: Double?,
        coveredDayCount: Int)
    {
        self.sourceID = sourceID
        self.provider = provider
        self.providerName = providerName
        self.subscriptionName = subscriptionName
        self.currencyCode = currencyCode
        self.totalTokens = totalTokens
        self.estimatedCost = estimatedCost
        self.coveredDayCount = coveredDayCount
    }
}

struct ShareStatsProviderRosterEntry: Sendable, Equatable {
    let provider: UsageProvider
    let providerName: String
    let currencyCode: String
    let expectedSourceIDs: Set<String>

    init(
        provider: UsageProvider,
        providerName: String,
        currencyCode: String,
        expectedSourceIDs: Set<String> = [])
    {
        self.provider = provider
        self.providerName = providerName
        self.currencyCode = currencyCode
        self.expectedSourceIDs = expectedSourceIDs
    }
}

struct ShareStatsModelPayload: Sendable, Equatable {
    let provider: UsageProvider
    let providerName: String
    let modelIdentity: String
    let modelName: String
    let currencyCode: String
    let totalTokens: Int?
    let estimatedCost: Double?
}

private struct ShareStatsModelFamilyKey: Hashable {
    let provider: UsageProvider
    let providerName: String
    let modelIdentity: String
    let modelName: String
    let currencyCode: String
}

private struct ShareStatsModelFamilyAccumulator {
    let key: ShareStatsModelFamilyKey
    private var totalTokens: Int?
    private var estimatedCost: Double?
    private var tokenOverflowed = false
    private var costOverflowed = false
    private var tokenIncomplete: Bool
    private var costIncomplete: Bool

    init(key: ShareStatsModelFamilyKey, row: ShareStatsModelPayload) {
        self.key = key
        self.totalTokens = row.totalTokens
        self.estimatedCost = row.estimatedCost
        self.tokenIncomplete = row.totalTokens == nil
        self.costIncomplete = row.estimatedCost == nil
    }

    mutating func add(_ row: ShareStatsModelPayload) {
        self.tokenIncomplete = self.tokenIncomplete || row.totalTokens == nil
        self.costIncomplete = self.costIncomplete || row.estimatedCost == nil
        if !self.tokenOverflowed, let value = row.totalTokens {
            if let totalTokens {
                let result = totalTokens.addingReportingOverflow(value)
                self.totalTokens = result.overflow ? nil : result.partialValue
                self.tokenOverflowed = result.overflow
            } else {
                self.totalTokens = value
            }
        }
        if !self.costOverflowed, let value = row.estimatedCost {
            if let estimatedCost {
                let total = estimatedCost + value
                self.estimatedCost = total.isFinite ? total : nil
                self.costOverflowed = !total.isFinite
            } else {
                self.estimatedCost = value
            }
        }
    }

    var payload: ShareStatsModelPayload? {
        let totalTokens = self.tokenIncomplete ? nil : self.totalTokens
        let estimatedCost = self.costIncomplete ? nil : self.estimatedCost
        guard totalTokens != nil || estimatedCost != nil else { return nil }
        return ShareStatsModelPayload(
            provider: self.key.provider,
            providerName: self.key.providerName,
            modelIdentity: self.key.modelIdentity,
            modelName: self.key.modelName,
            currencyCode: self.key.currencyCode,
            totalTokens: totalTokens,
            estimatedCost: estimatedCost)
    }
}

struct ShareStatsCurrencyPayload: Sendable, Equatable, Identifiable {
    let currencyCode: String
    let estimatedCost: Double?
    let coveredDayCount: Int
    var isPartial = false

    var id: String {
        self.currencyCode
    }
}

struct ShareStatsPayload: Sendable, Equatable {
    let days: Int
    let periodEnd: Date
    let providers: [ShareStatsProviderPayload]
    let topModels: [ShareStatsModelPayload]
    let currencies: [ShareStatsCurrencyPayload]
    let totalTokens: Int?
    let totalTokensIsPartial: Bool

    var hasShareableData: Bool {
        !self.providers.isEmpty && self.providers.contains { provider in
            provider.totalTokens != nil || provider.estimatedCost != nil
        }
    }

    var spendReportingProviderCount: Int {
        self.providers.count { $0.estimatedCost != nil }
    }
}

struct ShareStatsSubscriptionName: Sendable, Equatable {
    let displayName: String

    private init(displayName: String) {
        self.displayName = displayName
    }

    /// Converts plan-bearing provider identity into a closed, non-identifying share-card value.
    static func from(snapshot: UsageSnapshot?, provider: UsageProvider) -> Self? {
        guard let identity = snapshot?.identity(for: provider.instanceID),
              let rawName = identity.loginMethod,
              !Self.matchesAccountIdentity(rawName, identity: identity)
        else { return nil }

        let key = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let labels = ProviderDescriptorRegistry.descriptor(for: provider).metadata.sharePlanLabels
        guard !key.isEmpty, let displayName = labels[key] else { return nil }
        return Self(displayName: displayName)
    }

    static func first(from snapshots: [UsageSnapshot?], provider: UsageProvider) -> Self? {
        snapshots.lazy.compactMap { Self.from(snapshot: $0, provider: provider) }.first
    }

    private static func matchesAccountIdentity(_ rawName: String, identity: ProviderIdentitySnapshot) -> Bool {
        let candidate = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return [identity.accountEmail, identity.accountOrganization]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { $0.localizedCaseInsensitiveCompare(candidate) == .orderedSame }
    }
}

enum ShareStatsSanitizer {
    static func modelName(_ rawValue: String) -> String? {
        guard let value = self.safeLabel(
            rawValue,
            maximumLength: 96,
            maximumWords: 3,
            requireModelShape: true)
        else { return nil }

        let normalized = value.lowercased()
        guard !normalized.contains("://"), !normalized.contains("\\") else { return nil }
        let pathComponents = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard pathComponents.count <= 2,
              pathComponents.allSatisfy({ !$0.isEmpty })
        else { return nil }

        let routedModelName = String(pathComponents.last ?? "")
        let regionalPrefixes = ["us.", "eu.", "apac.", "global."]
        let familyName = regionalPrefixes.first { routedModelName.hasPrefix($0) }.map {
            String(routedModelName.dropFirst($0.count))
        } ?? routedModelName
        let publicModelFamilies: [(prefixes: [String], label: String)] = [
            (["amazon.nova-", "nova-"], "Amazon Nova"),
            (["anthropic.claude-", "claude-", "claude "], "Claude"),
            (["chatgpt-", "gpt-"], "GPT"),
            (["codex-"], "Codex"),
            (["command-"], "Command"),
            (["dall-e-"], "DALL-E"),
            (["deepseek-"], "DeepSeek"),
            (["codestral-", "devstral-", "magistral-", "mistral-", "mistral ", "mistral.", "mixtral-"], "Mistral"),
            (["gemma-"], "Gemma"),
            (["google.gemini-", "gemini-", "gemini "], "Gemini"),
            (["glm-"], "GLM"),
            (["grok-"], "Grok"),
            (["kimi-", "moonshot-"], "Kimi"),
            (["meta.llama", "llama-", "llama "], "Llama"),
            (["minimax-"], "MiniMax"),
            (["o1"], "o1"),
            (["o3"], "o3"),
            (["o4"], "o4"),
            (["phi-"], "Phi"),
            (["qwen"], "Qwen"),
            (["sonar-"], "Sonar"),
            (["text-embedding-"], "OpenAI Embeddings"),
            (["tts-"], "OpenAI TTS"),
            (["whisper-"], "Whisper"),
        ]
        guard let match = publicModelFamilies.lazy.compactMap({ family -> (String, String)? in
            guard let prefix = family.prefixes.first(where: familyName.hasPrefix) else { return nil }
            return (prefix, family.label)
        }).first else { return nil }

        let remainder = String(familyName.dropFirst(match.0.count))
        guard !remainder.isEmpty else { return match.1 }
        guard let detail = self.publicModelDetail(remainder) else { return nil }
        return "\(match.1) \(detail)"
    }

    private static func publicModelDetail(_ rawValue: String) -> String? {
        let displayTokens: [String: String] = [
            "air": "Air", "chat": "Chat", "code": "Code", "coder": "Coder", "codex": "Codex",
            "fable": "Fable", "fast": "Fast", "flash": "Flash", "free": "Free", "haiku": "Haiku",
            "instruct": "Instruct", "large": "Large", "lite": "Lite", "max": "Max",
            "latest": "Latest", "luna": "Luna", "medium": "Medium", "mini": "Mini", "nano": "Nano",
            "opus": "Opus",
            "oss": "OSS", "preview": "Preview", "pro": "Pro", "reasoning": "Reasoning",
            "small": "Small", "sol": "Sol", "sonnet": "Sonnet", "terra": "Terra", "thinking": "Thinking",
            "turbo": "Turbo", "vision": "Vision",
        ]
        let tokens = rawValue.split(whereSeparator: { "-_:".contains($0) }).map(String.init)
        var details: [String] = []
        var numericVersion: [String] = []

        func flushNumericVersion() {
            guard !numericVersion.isEmpty else { return }
            details.append(numericVersion.joined(separator: "."))
            numericVersion.removeAll(keepingCapacity: true)
        }

        for token in tokens {
            if token.allSatisfy(\.isNumber), token.count <= 3 {
                numericVersion.append(token)
                continue
            }
            flushNumericVersion()
            if token.range(of: #"^v[0-9]+$"#, options: .regularExpression) != nil ||
                token.range(of: #"^[0-9]{8}$"#, options: .regularExpression) != nil
            {
                break
            }
            if token.range(of: #"^[0-9]+(?:\.[0-9]+)+$"#, options: .regularExpression) != nil {
                details.append(token)
                continue
            }
            if let displayToken = displayTokens[token] {
                details.append(displayToken)
                continue
            }
            if token.range(of: #"^[a-z][0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil {
                details.append(token.uppercased())
                continue
            }
            if token.range(of: #"^[0-9]+b$"#, options: .regularExpression) != nil {
                details.append(token.uppercased())
                continue
            }
            if token.range(of: #"^[0-9]+o$"#, options: .regularExpression) != nil {
                details.append(token)
                continue
            }
            return nil
        }
        flushNumericVersion()
        guard !details.isEmpty else { return nil }
        return details.joined(separator: " ")
    }

    private static func safeLabel(
        _ rawValue: String,
        maximumLength: Int,
        maximumWords: Int,
        requireModelShape: Bool) -> String?
    {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= maximumLength,
              !value.contains("@"),
              !value.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue.map { $0 < 0x20 } == true }),
              value.split(whereSeparator: { $0.isWhitespace }).count <= maximumWords,
              value
                  .range(of: #"(?i)(^|[/\\])(?:Users|home|private|Volumes)([/\\]|$)"#, options: .regularExpression) ==
                  nil,
                  value.range(of: #"(?i)^[a-z]:\\"#, options: .regularExpression) == nil,
                  value.range(
                      of: #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
                      options: .regularExpression) == nil,
                  value.range(of: #"(?i)\b[0-9a-f]{24,}\b"#, options: .regularExpression) == nil,
                  value.range(of: #"^[\p{L}\p{N}][\p{L}\p{N} ._+:/()\-]*$"#, options: .regularExpression) != nil
        else { return nil }

        if requireModelShape {
            let hasModelPunctuation = value.contains { "-_/+.".contains($0) }
            guard hasModelPunctuation || value.contains(where: \Character.isNumber) else { return nil }
        }
        return value
    }
}

enum ShareStatsBuilder {
    static func make(
        model: SpendDashboardModel,
        subscriptionNames: [String: ShareStatsSubscriptionName] = [:],
        providerRoster: [ShareStatsProviderRosterEntry] = []) -> ShareStatsPayload?
    {
        let trackedProviders = model.groups.flatMap { group in
            group.providers.map { row in
                ShareStatsProviderPayload(
                    sourceID: row.id,
                    provider: row.provider,
                    providerName: row.displayName,
                    subscriptionName: subscriptionNames[row.id]?.displayName,
                    currencyCode: group.currencyCode,
                    totalTokens: row.totalTokens,
                    estimatedCost: self.finiteCost(row.totalCost),
                    coveredDayCount: row.coveredDayCount)
            }
        }
        let providers: [ShareStatsProviderPayload]
        if providerRoster.isEmpty {
            providers = trackedProviders
        } else {
            let trackedByProvider = Dictionary(grouping: trackedProviders, by: \.provider)
            var emittedProviders: Set<UsageProvider> = []
            providers = providerRoster.compactMap { entry in
                guard emittedProviders.insert(entry.provider).inserted else { return nil }
                let allMatches = trackedByProvider[entry.provider] ?? []
                let matches = self.rosterMatches(entry: entry, candidates: allMatches)
                guard !matches.isEmpty else {
                    return ShareStatsProviderPayload(
                        provider: entry.provider,
                        providerName: entry.providerName,
                        subscriptionName: nil,
                        currencyCode: entry.currencyCode,
                        totalTokens: nil,
                        estimatedCost: nil,
                        coveredDayCount: 0)
                }
                let knownCosts = matches.compactMap(\.estimatedCost)
                let currencyCodes = Set(matches.map(\.currencyCode))
                let coveredDayCount = matches.filter { $0.estimatedCost != nil || $0.totalTokens != nil }
                    .map(\.coveredDayCount)
                    .min() ?? 0
                return ShareStatsProviderPayload(
                    provider: entry.provider,
                    providerName: entry.providerName,
                    subscriptionName: matches.count == 1 ? matches[0].subscriptionName : nil,
                    currencyCode: matches[0].currencyCode,
                    totalTokens: self.combinedTotalTokens(matches.map(\.totalTokens)),
                    estimatedCost: currencyCodes.count == 1 ? self.safeCostSum(knownCosts) : nil,
                    coveredDayCount: coveredDayCount)
            }
        }
        let sanitizedModels = model.groups.filter {
            $0.modelHistoryCompleteness == .complete
        }.flatMap { group in
            group.models.compactMap { row -> ShareStatsModelPayload? in
                let estimatedCost = self.finiteCost(row.totalCost)
                guard let modelName = ShareStatsSanitizer.modelName(row.modelName),
                      row.totalTokens != nil
                else { return nil }
                return ShareStatsModelPayload(
                    provider: row.provider,
                    providerName: row.providerName,
                    modelIdentity: modelName.lowercased(),
                    modelName: modelName,
                    currencyCode: group.currencyCode,
                    totalTokens: row.totalTokens,
                    estimatedCost: estimatedCost)
            }
        }
        var modelFamilies: [ShareStatsModelFamilyKey: ShareStatsModelFamilyAccumulator] = [:]
        for row in sanitizedModels {
            let key = ShareStatsModelFamilyKey(
                provider: row.provider,
                providerName: row.providerName,
                modelIdentity: row.modelIdentity,
                modelName: row.modelName,
                currencyCode: row.currencyCode)
            if var existing = modelFamilies[key] {
                existing.add(row)
                modelFamilies[key] = existing
            } else {
                modelFamilies[key] = ShareStatsModelFamilyAccumulator(key: key, row: row)
            }
        }
        let topModels = modelFamilies.values.compactMap(\.payload).sorted { lhs, rhs in
            switch (lhs.totalTokens, rhs.totalTokens) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if lhs.providerName != rhs.providerName {
                    return lhs.providerName < rhs.providerName
                }
                if lhs.modelName != rhs.modelName {
                    return lhs.modelName < rhs.modelName
                }
                if lhs.currencyCode != rhs.currencyCode {
                    return lhs.currencyCode < rhs.currencyCode
                }
                return lhs.modelIdentity < rhs.modelIdentity
            }
        }
        let rosterProviderKinds = Set(providerRoster.map(\.provider))
        let rosterHasUnexpectedProviderFamilies = !providerRoster.isEmpty && trackedProviders.contains {
            !rosterProviderKinds.contains($0.provider)
        }
        let rosterHasIncompleteSpendProviders = rosterHasUnexpectedProviderFamilies ||
            providerRoster.contains { entry in
                let allMatches = trackedProviders.filter { $0.provider == entry.provider }
                let matches = self.rosterMatches(entry: entry, candidates: allMatches)
                let knownCosts = matches.compactMap(\.estimatedCost)
                return self.rosterIdentityIsIncomplete(entry: entry, candidates: allMatches) ||
                    matches.contains { $0.estimatedCost == nil } ||
                    Set(matches.map(\.currencyCode)).count > 1 ||
                    self.safeCostSum(knownCosts) == nil
            }
        let rosterHasIncompleteTokenProviders = rosterHasUnexpectedProviderFamilies ||
            providerRoster.contains { entry in
                let allMatches = trackedProviders.filter { $0.provider == entry.provider }
                let matches = self.rosterMatches(entry: entry, candidates: allMatches)
                return self.rosterIdentityIsIncomplete(entry: entry, candidates: allMatches) ||
                    matches.contains { $0.totalTokens == nil }
            }
        let rosterHasIncompleteProviders = rosterHasIncompleteSpendProviders ||
            rosterHasIncompleteTokenProviders
        let currencies = model.groups.map { group in
            let rosterCosts = providers.filter { $0.currencyCode == group.currencyCode }
                .compactMap(\.estimatedCost)
            let estimatedCost = providerRoster.isEmpty
                ? self.finiteCost(group.totalCost ?? group.knownCost)
                : self.safeCostSum(rosterCosts)
            return ShareStatsCurrencyPayload(
                currencyCode: group.currencyCode,
                estimatedCost: estimatedCost,
                coveredDayCount: group.coveredDayCount,
                isPartial: rosterHasIncompleteSpendProviders || group.totalCost == nil)
        }
        let tokenProviders = providerRoster.isEmpty ? trackedProviders : providers
        let knownTokenValues = tokenProviders.compactMap(\.totalTokens)
        let totalTokens = self.safeTokenSum(knownTokenValues)
        let totalTokensIsPartial = tokenProviders.contains { $0.totalTokens == nil } ||
            rosterHasIncompleteTokenProviders ||
            model.groups.contains { $0.totalTokens == nil }
        let periodEnd = model.groups.map(\.chartDomain.upperBound).max() ?? Date()
        let payload = ShareStatsPayload(
            days: model.requestedDays,
            periodEnd: periodEnd,
            providers: providers,
            topModels: rosterHasIncompleteProviders ? [] : topModels,
            currencies: currencies,
            totalTokens: totalTokens,
            totalTokensIsPartial: totalTokensIsPartial)
        return payload.hasShareableData ? payload : nil
    }

    private static func finiteCost(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func combinedTotalTokens(_ values: [Int?]) -> Int? {
        var total = 0
        for value in values {
            guard let value else { return nil }
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }

    private static func safeTokenSum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return values.isEmpty ? nil : total
    }

    private static func safeCostSum(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        var total = 0.0
        for value in values {
            total += value
            guard total.isFinite else { return nil }
        }
        return total
    }

    private static func rosterMatches(
        entry: ShareStatsProviderRosterEntry,
        candidates: [ShareStatsProviderPayload]) -> [ShareStatsProviderPayload]
    {
        guard !entry.expectedSourceIDs.isEmpty else { return candidates }
        return candidates.filter { candidate in
            candidate.sourceID.map(entry.expectedSourceIDs.contains) == true
        }
    }

    private static func rosterIdentityIsIncomplete(
        entry: ShareStatsProviderRosterEntry,
        candidates: [ShareStatsProviderPayload]) -> Bool
    {
        guard !entry.expectedSourceIDs.isEmpty else { return candidates.isEmpty }
        let actualIDs = Set(candidates.compactMap(\.sourceID))
        return actualIDs != entry.expectedSourceIDs || candidates.count != entry.expectedSourceIDs.count
    }
}

enum ShareStatsFormatting {
    static func compactCount(_ value: Int) -> String {
        let magnitude = abs(Double(value))
        let divisor: Double
        let suffix: String
        switch magnitude {
        case 1_000_000_000...: divisor = 1_000_000_000; suffix = "B"
        case 1_000_000...: divisor = 1_000_000; suffix = "M"
        case 1000...: divisor = 1000; suffix = "K"
        default: return value.formatted(.number.grouping(.automatic))
        }
        let scaled = Double(value) / divisor
        let digits = magnitude >= divisor * 100 ? 0 : magnitude >= divisor * 10 ? 1 : 2
        return scaled.formatted(.number.precision(.fractionLength(0...digits))) + suffix
    }

    static func currency(_ value: Double, code: String) -> String {
        UsageFormatter.currencyString(value, currencyCode: code)
    }

    static func dataThrough(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        return formatter.string(from: date)
    }

    static func text(_ payload: ShareStatsPayload) -> String {
        var lines = ["My AI subscriptions · last \(payload.days) days"]
        if let tokens = payload.totalTokens {
            let value = payload.totalTokensIsPartial ? "~\(self.compactCount(tokens))" : self.compactCount(tokens)
            lines.append("\(value) tracked tokens")
        }
        lines.append(
            "\(payload.spendReportingProviderCount)/\(payload.providers.count) connected services report spend")
        lines.append(contentsOf: payload.currencies.map { currency in
            let spend = currency.estimatedCost.map {
                let value = self.currency($0, code: currency.currencyCode)
                return "\(currency.isPartial ? "~" : "")\(value) estimated"
            }
                ?? "Spend unavailable"
            return "\(currency.currencyCode): \(spend) · "
                + "coverage \(currency.coveredDayCount)/\(payload.days) days"
        })
        lines.append(contentsOf: payload.providers.map { provider in
            var metrics: [String] = []
            if let tokens = provider.totalTokens {
                metrics.append("\(self.compactCount(tokens)) tokens")
            }
            if let cost = provider.estimatedCost {
                metrics.append("~\(self.currency(cost, code: provider.currencyCode)) est")
            } else {
                metrics.append("Spend unavailable")
            }
            if provider.estimatedCost != nil, provider.coveredDayCount < payload.days {
                metrics.append("\(provider.coveredDayCount)/\(payload.days) days")
            }
            let subscription = provider.subscriptionName.map { " · \($0)" } ?? ""
            return "\(provider.providerName)\(subscription): \(metrics.joined(separator: " · "))"
        })
        if !payload.topModels.isEmpty {
            lines.append("Top models:")
            lines.append(contentsOf: payload.topModels.prefix(5).map { model in
                var metrics: [String] = []
                if let tokens = model.totalTokens {
                    metrics.append("\(self.compactCount(tokens)) tokens")
                }
                if let cost = model.estimatedCost {
                    metrics.append("~\(self.currency(cost, code: model.currencyCode)) est")
                }
                return "\(model.modelName) (\(model.providerName)): \(metrics.joined(separator: " · "))"
            })
            if payload.topModels.count > 5 {
                lines.append("+\(payload.topModels.count - 5) more models ranked in local stats")
            }
        }
        lines.append("Generated locally by CodexBar · Data through \(self.dataThrough(payload.periodEnd))")
        return lines.joined(separator: "\n")
    }
}
