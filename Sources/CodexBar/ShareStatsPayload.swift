import CodexBarCore
import Foundation

struct ShareStatsProviderPayload: Sendable, Equatable {
    let provider: UsageProvider
    let providerName: String
    let subscriptionName: String?
    let currencyCode: String
    let totalTokens: Int?
    let estimatedCost: Double?
    let coveredDayCount: Int
}

struct ShareStatsModelPayload: Sendable, Equatable {
    let provider: UsageProvider
    let providerName: String
    let modelName: String
    let currencyCode: String
    let totalTokens: Int?
    let estimatedCost: Double?
}

private struct ShareStatsModelFamilyKey: Hashable {
    let provider: UsageProvider
    let providerName: String
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
    let isPartial: Bool

    init(
        currencyCode: String,
        estimatedCost: Double?,
        coveredDayCount: Int,
        isPartial: Bool = false)
    {
        self.currencyCode = currencyCode
        self.estimatedCost = estimatedCost
        self.coveredDayCount = coveredDayCount
        self.isPartial = isPartial
    }

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
    let hasPartialTokens: Bool

    init(
        days: Int,
        periodEnd: Date,
        providers: [ShareStatsProviderPayload],
        topModels: [ShareStatsModelPayload],
        currencies: [ShareStatsCurrencyPayload],
        totalTokens: Int?,
        hasPartialTokens: Bool = false)
    {
        self.days = days
        self.periodEnd = periodEnd
        self.providers = providers
        self.topModels = topModels
        self.currencies = currencies
        self.totalTokens = totalTokens
        self.hasPartialTokens = hasPartialTokens
    }

    var hasShareableData: Bool {
        !self.providers.isEmpty && self.providers.contains { provider in
            provider.totalTokens != nil || provider.estimatedCost != nil
        }
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
            maximumLength: 72,
            maximumWords: 3,
            requireModelShape: true)
        else { return nil }

        let normalized = value.lowercased()
        let regionalPrefixes = ["us.", "eu.", "apac.", "global."]
        let familyName = regionalPrefixes.first { normalized.hasPrefix($0) }.map {
            String(normalized.dropFirst($0.count))
        } ?? normalized
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
        guard !normalized.contains("://"),
              !normalized.contains("/"),
              !normalized.contains("\\")
        else { return nil }
        return publicModelFamilies.first { family in
            family.prefixes.contains(where: familyName.hasPrefix)
        }?.label
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
        subscriptionNames: [String: ShareStatsSubscriptionName] = [:]) -> ShareStatsPayload?
    {
        let hasNonProxyProvider = model.groups.contains { group in
            group.providers.contains { $0.id != SpendDashboardSource.codexProxySourceID }
        }
        let providers = model.groups.flatMap { group in
            group.providers.compactMap { row -> ShareStatsProviderPayload? in
                // The proxy source is not an account or subscription. Keep excluding it beside native
                // providers, but retain it when it is the only provider so proxy-only usage stays shareable.
                guard row.id != SpendDashboardSource.codexProxySourceID || !hasNonProxyProvider else { return nil }
                return ShareStatsProviderPayload(
                    provider: row.provider,
                    providerName: row.displayName,
                    subscriptionName: subscriptionNames[row.id]?.displayName,
                    currencyCode: group.currencyCode,
                    totalTokens: row.totalTokens,
                    estimatedCost: self.finiteCost(row.totalCost),
                    coveredDayCount: row.coveredDayCount)
            }
        }
        let sanitizedModels = model.groups.filter {
            $0.modelHistoryCompleteness == .complete
        }.flatMap { group in
            group.models.compactMap { row -> ShareStatsModelPayload? in
                let estimatedCost = self.finiteCost(row.totalCost)
                guard let modelName = self.sharedModelName(for: row),
                      let sharedProvider = self.sharedModelProvider(for: row),
                      row.totalTokens != nil
                else { return nil }
                return ShareStatsModelPayload(
                    provider: sharedProvider.provider,
                    providerName: sharedProvider.name,
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
                return lhs.modelName < rhs.modelName
            }
        }
        let currencies = model.groups.map {
            ShareStatsCurrencyPayload(
                currencyCode: $0.currencyCode,
                estimatedCost: self.finiteCost($0.totalCost),
                coveredDayCount: $0.coveredDayCount,
                isPartial: $0.hasPartialCost)
        }
        let totalTokens = self.combinedTotalTokens(model.groups.map(\.totalTokens))
        let hasPartialTokens = model.groups.contains(where: \.hasPartialTokens)
        let periodEnd = model.groups.map(\.chartDomain.upperBound).max() ?? Date()
        let payload = ShareStatsPayload(
            days: model.requestedDays,
            periodEnd: periodEnd,
            providers: providers,
            topModels: topModels,
            currencies: currencies,
            totalTokens: totalTokens,
            hasPartialTokens: hasPartialTokens)
        return payload.hasShareableData ? payload : nil
    }

    private static func sharedModelName(for row: SpendDashboardModel.ModelRow) -> String? {
        guard row.attribution?.route == .cliProxyAPI else {
            return ShareStatsSanitizer.modelName(row.modelName)
        }
        guard let upstreamModel = row.attribution?.upstream?.model else { return nil }
        return ShareStatsSanitizer.modelName(upstreamModel)
    }

    private static func sharedModelProvider(
        for row: SpendDashboardModel.ModelRow) -> (provider: UsageProvider, name: String)?
    {
        guard row.attribution?.route == .cliProxyAPI else {
            return (row.provider, row.providerName)
        }
        guard let upstream = row.attribution?.upstream else { return nil }
        let normalizedProvider = upstream.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Provider-specific by design: CLIProxyAPI provider strings map to CodexBar's canonical provider IDs.
        let provider: UsageProvider? = switch normalizedProvider {
        case "anthropic": .claude
        case "aistudio", "gemini-interactions", "google": .gemini
        case "vertex": .vertexai
        default: UsageProvider(rawValue: normalizedProvider)
        }
        guard let provider else { return nil }
        return (provider, ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName)
    }

    private static func finiteCost(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func combinedTotalTokens(_ values: [Int?]) -> Int? {
        let known = values.compactMap(\.self)
        guard !known.isEmpty else { return nil }
        var total = 0
        for value in known {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
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

    static func isAllTime(_ payload: ShareStatsPayload) -> Bool {
        payload.days >= SpendDashboardSource.scanDays
    }

    static func periodHeadline(_ payload: ShareStatsPayload) -> String {
        self.isAllTime(payload)
            ? "My AI subscriptions · all time"
            : "My AI subscriptions · last \(payload.days) days"
    }

    static func coverageFraction(covered: Int, payload: ShareStatsPayload) -> String {
        self.isAllTime(payload)
            ? "\(covered)/all"
            : "\(covered)/\(payload.days) days"
    }

    static func text(_ payload: ShareStatsPayload) -> String {
        var lines = [self.periodHeadline(payload)]
        if let tokens = payload.totalTokens {
            let count = self.compactCount(tokens)
            lines.append(
                payload.hasPartialTokens
                    ? "~\(count) tracked tokens (partial)"
                    : "\(count) tracked tokens")
        }
        lines.append(contentsOf: payload.currencies.map { currency in
            let spend = currency.estimatedCost.map { value in
                let amount = "\(self.currency(value, code: currency.currencyCode)) estimated"
                return currency.isPartial ? "\(amount) (partial)" : amount
            } ?? "Spend unavailable"
            let coverage = self.coverageFraction(covered: currency.coveredDayCount, payload: payload)
            return "\(currency.currencyCode): \(spend) · coverage \(coverage)"
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
                metrics.append(self.coverageFraction(covered: provider.coveredDayCount, payload: payload))
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
        }
        lines.append("Generated locally by CodexBar · Data through \(self.dataThrough(payload.periodEnd))")
        return lines.joined(separator: "\n")
    }
}
