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
        let providers = model.groups.flatMap { group in
            group.providers.map { row in
                ShareStatsProviderPayload(
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
                guard let modelName = ShareStatsSanitizer.modelName(row.modelName),
                      row.totalTokens != nil
                else { return nil }
                return ShareStatsModelPayload(
                    provider: row.provider,
                    providerName: row.providerName,
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
                coveredDayCount: $0.coveredDayCount)
        }
        let totalTokens = self.combinedTotalTokens(model.groups.map(\.totalTokens))
        let periodEnd = model.groups.map(\.chartDomain.upperBound).max() ?? Date()
        let payload = ShareStatsPayload(
            days: model.requestedDays,
            periodEnd: periodEnd,
            providers: providers,
            topModels: topModels,
            currencies: currencies,
            totalTokens: totalTokens)
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
            lines.append("\(self.compactCount(tokens)) tracked tokens")
        }
        lines.append(contentsOf: payload.currencies.map { currency in
            let spend = currency.estimatedCost.map { "\(self.currency($0, code: currency.currencyCode)) estimated" }
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
        }
        lines.append("Generated locally by CodexBar · Data through \(self.dataThrough(payload.periodEnd))")
        return lines.joined(separator: "\n")
    }
}
