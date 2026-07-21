import CodexBarCore
import Foundation

struct ShareStatsProviderPayload: Sendable, Equatable {
    let sourceID: String
    let provider: UsageProvider
    let providerName: String
    let subscriptionName: String?
    let currencyCode: String
    let totalTokens: Int?
    let estimatedCost: Double?
    let coveredDayCount: Int
}

struct ShareStatsModelPayload: Sendable, Equatable {
    let sourceID: String
    let provider: UsageProvider
    let providerName: String
    let sourceName: String
    let modelName: String
    let currencyCode: String
    let totalTokens: Int?
    let estimatedCost: Double?
}

private struct ShareStatsModelFamilyKey: Hashable {
    let sourceID: String
    let provider: UsageProvider
    let providerName: String
    let sourceName: String
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
            sourceID: self.key.sourceID,
            provider: self.key.provider,
            providerName: self.key.providerName,
            sourceName: self.key.sourceName,
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
    let pricedSourceCount: Int
    let sourceCount: Int

    var id: String {
        self.currencyCode
    }
}

struct ShareStatsDailyPayload: Sendable, Equatable, Identifiable {
    let day: Date
    let totalTokens: Int?

    var id: Date {
        self.day
    }
}

struct ShareStatsPayload: Sendable, Equatable {
    let days: Int
    let periodEnd: Date
    let providers: [ShareStatsProviderPayload]
    let topModels: [ShareStatsModelPayload]
    let currencies: [ShareStatsCurrencyPayload]
    let dailyTokens: [ShareStatsDailyPayload]
    let dailySourceCount: Int
    let dailyFullSourceCount: Int
    let modelRouteCount: Int
    let shareableModelRouteCount: Int
    let hiddenModelRouteCount: Int
    let modelRouteCoverageIsComplete: Bool
    let totalTokens: Int?
    let tokenSourceCount: Int

    var dailyCoverageIsComplete: Bool {
        !self.providers.isEmpty && self.dailyFullSourceCount == self.providers.count
    }

    var tokenCoverageIsComplete: Bool {
        self.totalTokens != nil && self.tokenSourceCount == self.providers.count
    }

    var hasUnavailableDailyTotals: Bool {
        self.dailyTokens.contains { $0.totalTokens == nil }
    }

    var hasShareableData: Bool {
        !self.providers.isEmpty && self.providers.contains { $0.totalTokens != nil }
    }
}

struct ShareStatsSubscriptionName: Sendable, Equatable {
    let displayName: String

    private init(displayName: String) {
        self.displayName = displayName
    }

    private static let labelsByProvider: [String: [String: String]] = [
        UsageProvider.codex.rawValue: [
            "guest": "Guest", "free": "Free", "go": "Go", "plus": "Plus", "plus plan": "Plus",
            "chatgpt plus": "Plus", "chatgpt-plus": "Plus", "chatgpt_plus": "Plus",
            "pro": "Pro 20x", "codex pro": "Pro 20x",
            "prolite": "Pro 5x", "pro_lite": "Pro 5x", "pro-lite": "Pro 5x",
            "pro lite": "Pro 5x", "codex pro lite": "Pro 5x",
            "free_workspace": "Free Workspace", "team": "Team", "business": "Business",
            "education": "Education", "quorum": "Quorum", "k12": "K12",
            "enterprise": "Enterprise", "edu": "Edu",
        ],
        UsageProvider.claude.rawValue: [
            "free": "Free", "claude free": "Free", "pro": "Pro", "claude pro": "Pro",
            "max": "Max", "claude max": "Max", "max 5x": "Max 5x", "claude max 5x": "Max 5x",
            "max 20x": "Max 20x", "claude max 20x": "Max 20x", "team": "Team",
            "claude team": "Team", "claude team standard": "Team Standard",
            "claude team premium": "Team Premium", "enterprise": "Enterprise",
            "claude enterprise": "Enterprise", "ultra": "Ultra", "claude ultra": "Ultra",
        ],
        UsageProvider.cursor.rawValue: [
            "free": "Cursor Free", "cursor free": "Cursor Free",
            "hobby": "Cursor Hobby", "cursor hobby": "Cursor Hobby",
            "pro": "Cursor Pro", "cursor pro": "Cursor Pro",
            "team": "Cursor Team", "cursor team": "Cursor Team",
            "business": "Cursor Business", "cursor business": "Cursor Business",
            "enterprise": "Cursor Enterprise", "cursor enterprise": "Cursor Enterprise",
            "ultra": "Cursor Ultra", "cursor ultra": "Cursor Ultra",
        ],
        UsageProvider.alibaba.rawValue: [
            "lite": "Lite", "coding plan lite": "Lite", "pro": "Pro", "active pro": "Pro",
            "alibaba coding plan pro": "Pro", "starter": "Starter", "enterprise": "Enterprise",
        ],
        UsageProvider.alibabatokenplan.rawValue: [
            "token plan": "Token Plan", "token plan pro": "Token Plan Pro",
            "token plan plus": "Token Plan Plus",
        ],
        UsageProvider.gemini.rawValue: [
            "free": "Free", "paid": "Paid", "plus": "Plus", "workspace": "Workspace",
            "legacy": "Legacy", "gemini code assist in google one ai pro": "Google One AI Pro",
        ],
        UsageProvider.antigravity.rawValue: [
            "free": "Free", "paid": "Paid", "pro": "Pro",
            "ultra": "Google AI Ultra", "google ai ultra": "Google AI Ultra",
        ],
        UsageProvider.copilot.rawValue: [
            "free": "Free", "individual": "Individual", "pro": "Individual",
            "business": "Business", "enterprise": "Enterprise",
        ],
        UsageProvider.devin.rawValue: [
            "free": "Free", "core": "Core", "pro": "Pro", "team": "Team", "enterprise": "Enterprise",
        ],
        UsageProvider.zai.rawValue: [
            "free": "Free", "pro": "Pro", "max": "Max", "team": "Team",
        ],
        UsageProvider.minimax.rawValue: [
            "free": "Free", "pro": "Pro", "plus": "Plus", "max": "Max", "ultra": "Ultra",
            "minimax star": "MiniMax Star", "combo star": "Combo Star", "coding plan pro": "Coding Plan Pro",
            "token plan pro": "Token Plan Pro", "token plan · tokenplanplus-年度会员": "Token Plan Plus",
            "tokenplanplus-年度会员": "Token Plan Plus", "tokenplanmax-年度会员": "Token Plan Max",
            "tokenplanultra-年度会员": "Token Plan Ultra",
        ],
        UsageProvider.augment.rawValue: [
            "free": "Free", "community": "Community", "indie": "Indie", "pro": "Pro",
            "team": "Team", "enterprise": "Enterprise",
        ],
        UsageProvider.elevenlabs.rawValue: [
            "free": "Free", "starter": "Starter", "creator": "Creator", "pro": "Pro",
            "scale": "Scale", "business": "Business", "growing business": "Business",
            "enterprise": "Enterprise",
        ],
        UsageProvider.windsurf.rawValue: [
            "free": "Free", "pro": "Pro", "team": "Teams", "teams": "Teams",
            "enterprise": "Enterprise", "ultimate": "Ultimate",
        ],
        UsageProvider.zed.rawValue: [
            "zed free": "Zed Free", "zed pro": "Zed Pro", "zed pro trial": "Zed Pro Trial",
            "zed student": "Zed Student", "zed business": "Zed Business",
        ],
        UsageProvider.perplexity.rawValue: ["pro": "Pro", "max": "Max"],
        UsageProvider.sakana.rawValue: [
            "standard": "Standard", "standard $20/mo": "Standard", "pro": "Pro", "enterprise": "Enterprise",
        ],
        UsageProvider.abacus.rawValue: [
            "basic": "Basic", "pro": "Pro", "team": "Team", "enterprise": "Enterprise",
        ],
        UsageProvider.synthetic.rawValue: [
            "starter": "Starter", "pro": "Pro", "team": "Team", "enterprise": "Enterprise",
        ],
        UsageProvider.t3chat.rawValue: ["free": "Free", "pro": "Pro", "team": "Team"],
        UsageProvider.sub2api.rawValue: [
            "free": "Free", "pro": "Pro", "team": "Team", "claude team": "Team",
            "enterprise": "Enterprise", "wallet plan": "Wallet",
        ],
    ]

    /// Converts plan-bearing provider identity into a closed, non-identifying share-card value.
    static func from(snapshot: UsageSnapshot?, provider: UsageProvider) -> Self? {
        guard let identity = snapshot?.identity(for: provider),
              let rawName = identity.loginMethod,
              !Self.matchesAccountIdentity(rawName, identity: identity)
        else { return nil }

        let key = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, let displayName = Self.labelsByProvider[provider.rawValue]?[key] else { return nil }
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
        if rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare("Fable") == .orderedSame
        {
            return "Fable"
        }
        guard let value = self.safeLabel(
            rawValue,
            maximumLength: 72,
            maximumWords: 3,
            requireModelShape: true)
        else { return nil }

        var normalized = value.lowercased()
        let pathParts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        if pathParts.count == 2 {
            let publicPublishers: Set = [
                "alibaba", "amazon", "anthropic", "cohere", "deepseek", "fable", "google",
                "meta-llama", "microsoft", "minimax", "mistralai", "moonshotai", "openai",
                "perplexity", "qwen", "x-ai", "z-ai",
            ]
            guard publicPublishers.contains(String(pathParts[0])), !pathParts[1].isEmpty else { return nil }
            normalized = String(pathParts[1])
        } else if pathParts.count > 1 {
            return nil
        }
        let regionalPrefixes = ["us.", "eu.", "apac.", "global."]
        let familyName = regionalPrefixes.first { normalized.hasPrefix($0) }.map {
            String(normalized.dropFirst($0.count))
        } ?? normalized
        guard !familyName.contains("://"), !familyName.contains("\\"), !familyName.contains("/") else { return nil }

        if let suffix = self.suffix(in: familyName, after: ["chatgpt-", "gpt-"]),
           let canonical = self.canonicalSuffix(
               suffix,
               allowedStarts: ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        {
            return "GPT-\(self.prettySuffix(canonical))"
        }
        if let suffix = self.suffix(in: familyName, after: ["anthropic.claude-", "claude-", "claude "]),
           let canonical = self.canonicalSuffix(
               suffix,
               allowedStarts: ["opus", "sonnet", "haiku", "instant", "1", "2", "3", "4", "5", "6", "7", "8", "9"])
        {
            return "Claude \(self.prettySuffix(canonical))"
        }

        let families: [(prefixes: [String], label: String, allowedStarts: [String])] = [
            (
                ["amazon.nova-", "nova-"],
                "Amazon Nova",
                ["lite", "micro", "pro", "premier", "canvas", "reel", "sonic", "1", "2", "3", "4", "5"]),
            (["codex-"], "Codex", ["mini", "max", "1", "2", "3", "4", "5", "6", "7", "8", "9"]),
            (["command-"], "Command", ["a", "r", "light", "nightly"]),
            (["dall-e-"], "DALL-E", ["2", "3"]),
            (["deepseek-"], "DeepSeek", ["r", "v", "chat", "coder"]),
            (["fable-"], "Fable", ["1", "2", "3", "4", "5", "6", "7", "8", "9"]),
            (["gemma-"], "Gemma", ["1", "2", "3", "4", "5", "6", "7", "8", "9"]),
            (["google.gemini-", "gemini-", "gemini "], "Gemini", ["1", "2", "3", "4", "5", "6", "7", "8", "9"]),
            (["glm-"], "GLM", ["1", "2", "3", "4", "5", "6", "7", "8", "9"]),
            (["grok-"], "Grok", ["1", "2", "3", "4", "5", "6", "7", "8", "9"]),
            (["kimi-", "moonshot-"], "Kimi", ["k", "1", "2", "3", "4", "5", "6", "7", "8", "9"]),
            (["meta.llama", "llama-", "llama "], "Llama", ["1", "2", "3", "4", "5", "6", "7", "8", "9"]),
            (["minimax-"], "MiniMax", ["m", "text", "speech", "video", "image", "1", "2", "3"]),
            (["phi-"], "Phi", ["1", "2", "3", "4", "5", "6", "7", "8", "9"]),
            (["qwen"], "Qwen", ["1", "2", "3", "4", "5", "6", "7", "8", "9"]),
            (["sonar-"], "Sonar", ["small", "medium", "large", "pro", "reasoning", "deep"]),
        ]
        for family in families {
            guard let suffix = self.suffix(in: familyName, after: family.prefixes),
                  let canonical = self.canonicalSuffix(suffix, allowedStarts: family.allowedStarts)
            else { continue }
            return "\(family.label) \(self.prettySuffix(canonical))"
        }

        for base in ["o1", "o3", "o4"] where familyName.hasPrefix(base) {
            let tail = String(familyName.dropFirst(base.count))
            guard tail.isEmpty else {
                guard tail.hasPrefix("-"),
                      let canonical = self.canonicalSuffix(
                          String(tail.dropFirst()),
                          allowedStarts: ["mini", "pro", "preview"])
                else { return base.uppercased() }
                return "\(base.uppercased()) \(self.prettySuffix(canonical))"
            }
            return base.uppercased()
        }
        if let suffix = self.suffix(in: familyName, after: [
            "codestral-", "devstral-", "magistral-", "mistral-", "mistral ", "mistral.", "mixtral-",
        ]), let canonical = self.canonicalSuffix(
            suffix,
            allowedStarts: ["small", "medium", "large", "1", "2", "3", "4", "5", "6", "7", "8", "9"])
        {
            return "Mistral \(self.prettySuffix(canonical))"
        }
        if let suffix = self.suffix(in: familyName, after: ["text-embedding-"]),
           let canonical = self.canonicalSuffix(
               suffix,
               allowedStarts: ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        {
            return "OpenAI Embeddings \(self.prettySuffix(canonical))"
        }
        if let suffix = self.suffix(in: familyName, after: ["tts-", "whisper-"]),
           let canonical = self.canonicalSuffix(
               suffix,
               allowedStarts: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "large", "turbo"])
        {
            return familyName.hasPrefix("tts-")
                ? "OpenAI TTS \(self.prettySuffix(canonical))"
                : "Whisper \(self.prettySuffix(canonical))"
        }
        return nil
    }

    private static func suffix(in value: String, after prefixes: [String]) -> String? {
        guard let prefix = prefixes.first(where: value.hasPrefix) else { return nil }
        let suffix = String(value.dropFirst(prefix.count))
        return suffix.isEmpty ? nil : suffix
    }

    private static func canonicalSuffix(_ value: String, allowedStarts: [String]) -> String? {
        let parts = value
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)
        guard let first = parts.first,
              allowedStarts.contains(where: { self.isAllowedPublicStart(first, allowedStart: $0) })
        else { return nil }

        let publicQualifiers: Set = [
            "a", "air", "canvas", "chat", "coder", "deep", "flash", "image", "instruct",
            "large", "lite", "max", "medium", "micro", "mini", "nano", "nightly", "plus",
            "premier", "preview", "pro", "r", "reasoning", "reel", "small", "sonic", "speech",
            "text", "thinking", "turbo", "video",
        ]
        var canonical = [first]
        for part in parts.dropFirst().prefix(4) {
            let isVersion = part.range(
                of: #"^(?:[vkr]?\d+(?:\.\d+)*(?::\d+)?|\d{8})$"#,
                options: .regularExpression) != nil
            guard isVersion || publicQualifiers.contains(part) else { break }
            canonical.append(part)
        }
        return canonical.joined(separator: "-")
    }

    private static func isAllowedPublicStart(_ value: String, allowedStart: String) -> Bool {
        guard value.hasPrefix(allowedStart) else { return false }
        let suffix = String(value.dropFirst(allowedStart.count))
        guard !suffix.isEmpty else { return true }
        return suffix.range(
            of: #"^(?:\d+(?:\.\d+)*|\.\d+(?:\.\d+)*)(?::\d+)?$"#,
            options: .regularExpression) != nil
    }

    private static func prettySuffix(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map { part in
                let value = String(part)
                return value.count <= 3 ? value.uppercased() : value.capitalized
            }
            .joined(separator: " ")
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
        let sourceLabels = self.publicSourceLabels(model: model)
        let providers = model.groups.flatMap { group in
            group.providers.map { row in
                ShareStatsProviderPayload(
                    sourceID: row.id,
                    provider: row.provider,
                    providerName: sourceLabels[row.id]
                        ?? ProviderDescriptorRegistry.descriptor(for: row.provider).metadata.displayName,
                    subscriptionName: subscriptionNames[row.id]?.displayName,
                    currencyCode: group.currencyCode,
                    totalTokens: row.totalTokens,
                    estimatedCost: self.finiteCost(row.totalCost),
                    coveredDayCount: row.coveredDayCount)
            }
        }
        let observedModels = model.groups.flatMap { group in
            group.tokenModels.map { (currencyCode: group.currencyCode, row: $0) }
        }
        let sanitizedModels = observedModels.compactMap { entry -> ShareStatsModelPayload? in
            let row = entry.row
            let estimatedCost = self.finiteCost(row.totalCost)
            guard let modelName = ShareStatsSanitizer.modelName(row.modelName),
                  row.totalTokens != nil
            else { return nil }
            return ShareStatsModelPayload(
                sourceID: row.sourceID,
                provider: row.provider,
                providerName: row.providerName,
                sourceName: sourceLabels[row.sourceID] ?? row.providerName,
                modelName: modelName,
                currencyCode: entry.currencyCode,
                totalTokens: row.totalTokens,
                estimatedCost: estimatedCost)
        }
        var modelFamilies: [ShareStatsModelFamilyKey: ShareStatsModelFamilyAccumulator] = [:]
        for row in sanitizedModels {
            let key = ShareStatsModelFamilyKey(
                sourceID: row.sourceID,
                provider: row.provider,
                providerName: row.providerName,
                sourceName: row.sourceName,
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
                if lhs.sourceName != rhs.sourceName {
                    return lhs.sourceName < rhs.sourceName
                }
                return lhs.modelName < rhs.modelName
            }
        }
        let currencies = model.groups.map { group in
            let knownCosts = group.providers.compactMap { self.finiteCost($0.totalCost) }
            return ShareStatsCurrencyPayload(
                currencyCode: group.currencyCode,
                estimatedCost: knownCosts.isEmpty ? nil : self.combinedKnownCost(knownCosts),
                coveredDayCount: group.coveredDayCount,
                pricedSourceCount: knownCosts.count,
                sourceCount: group.providers.count)
        }
        let dailyPoints = model.groups.flatMap(\.dailyTokenPoints)
        let dailyPointsByDay = Dictionary(grouping: dailyPoints, by: \.day)
        let dailyTokens = dailyPointsByDay
            .keys
            .sorted()
            .map { day -> ShareStatsDailyPayload in
                let points = dailyPointsByDay[day] ?? []
                let total = self.combinedTotalTokens(points.map { Optional($0.tokens) })
                return ShareStatsDailyPayload(day: day, totalTokens: total)
            }
        let dailySourceCount = providers.count { $0.totalTokens != nil }
        let dailyFullSourceCount = providers.count {
            $0.totalTokens != nil && $0.coveredDayCount >= model.requestedDays
        }
        let knownTokenTotals = providers.compactMap(\.totalTokens)
        let totalTokens = knownTokenTotals.isEmpty ? nil : self.combinedTotalTokens(knownTokenTotals.map(Optional.some))
        let periodEnd = model.groups.map { group in
            let bounds = group.chartDomain
            return bounds.lowerBound < bounds.upperBound
                ? Calendar.current.date(byAdding: .day, value: -1, to: bounds.upperBound)
                ?? bounds.upperBound
                : bounds.upperBound
        }.max()
            ?? Date()
        let payload = ShareStatsPayload(
            days: model.requestedDays,
            periodEnd: periodEnd,
            providers: providers,
            topModels: topModels,
            currencies: currencies,
            dailyTokens: dailyTokens,
            dailySourceCount: dailySourceCount,
            dailyFullSourceCount: dailyFullSourceCount,
            modelRouteCount: observedModels.count,
            shareableModelRouteCount: sanitizedModels.count,
            hiddenModelRouteCount: observedModels.count - sanitizedModels.count,
            modelRouteCoverageIsComplete: model.groups.allSatisfy {
                $0.modelTokenHistoryCompleteness == .complete
            },
            totalTokens: totalTokens,
            tokenSourceCount: knownTokenTotals.count)
        return payload.hasShareableData ? payload : nil
    }

    private static func publicSourceLabels(model: SpendDashboardModel) -> [String: String] {
        let rows = model.groups.flatMap(\.providers)
        let rowsByProvider = Dictionary(grouping: rows, by: \.provider)
        var labels: [String: String] = [:]
        for (provider, providerRows) in rowsByProvider {
            let baseName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
            let sortedRows = providerRows.sorted { $0.id < $1.id }
            for (index, row) in sortedRows.enumerated() {
                labels[row.id] = sortedRows.count == 1 ? baseName : "\(baseName) #\(index + 1)"
            }
        }
        return labels
    }

    private static func finiteCost(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func combinedKnownCost(_ values: [Double]) -> Double? {
        var total = 0.0
        for value in values {
            total += value
            guard total.isFinite else { return nil }
        }
        return total
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

    static func shortDay(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }

    static func shortRange(from start: Date, through end: Date, calendar: Calendar = .current) -> String {
        "\(self.shortDay(start, calendar: calendar)) — \(self.shortDay(end, calendar: calendar))"
    }

    static func text(
        _ payload: ShareStatsPayload,
        style: ShareStatsCardStyle = .defaultStyle) -> String
    {
        switch style {
        case .summary:
            self.summaryText(payload)
        case .modelActivity:
            self.modelActivityText(payload)
        }
    }

    private static func summaryText(_ payload: ShareStatsPayload) -> String {
        var lines = ["My AI subscriptions · last \(payload.days) days"]
        if let tokens = payload.totalTokens {
            let qualifier = payload.tokenCoverageIsComplete ? "" : "at least "
            lines.append("\(qualifier)\(self.compactCount(tokens)) tracked tokens")
        }
        lines.append(contentsOf: payload.currencies.map { currency in
            let spend = currency.estimatedCost.map { cost in
                let value = self.currency(cost, code: currency.currencyCode)
                let isPartial = currency.pricedSourceCount < currency.sourceCount
                    || currency.coveredDayCount < payload.days
                return isPartial ? "at least \(value) estimated" : "\(value) estimated"
            } ?? "Spend unavailable"
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
                return "\(model.modelName) (\(model.sourceName)): \(metrics.joined(separator: " · "))"
            })
        }
        lines.append("Generated locally by CodexBar · Data through \(self.dataThrough(payload.periodEnd))")
        return lines.joined(separator: "\n")
    }

    private static func modelActivityText(_ payload: ShareStatsPayload) -> String {
        var lines = ["You kept the models busy · last \(payload.days) days"]
        if let tokens = payload.totalTokens {
            let qualifier = payload.tokenCoverageIsComplete ? "" : "at least "
            lines.append("\(qualifier)\(self.compactCount(tokens)) tracked tokens")
        }
        if !payload.dailyTokens.isEmpty {
            let activeDays = payload.dailyTokens.count { ($0.totalTokens ?? 0) > 0 }
            let qualifier = payload.dailyCoverageIsComplete && !payload.hasUnavailableDailyTotals ? "" : "at least "
            lines.append("\(qualifier)\(activeDays) of \(payload.days) days active")
        }
        let pricedCurrencies = payload.currencies.compactMap { currency in
            currency.estimatedCost.map { cost in
                let value = self.currency(cost, code: currency.currencyCode)
                let isPartial = currency.pricedSourceCount < currency.sourceCount
                    || currency.coveredDayCount < payload.days
                return isPartial ? "≥\(value)" : value
            }
        }
        let pricedSourceCount = payload.providers.count { $0.estimatedCost != nil }
        if !pricedCurrencies.isEmpty {
            lines.append(
                "Estimated token spend: \(pricedCurrencies.joined(separator: " · "))"
                    + " · pricing for \(pricedSourceCount) of \(payload.providers.count) sources")
        }
        if !payload.topModels.isEmpty {
            lines.append("Top model routes:")
            lines.append(contentsOf: payload.topModels.prefix(3).map { model in
                "\(model.modelName) via \(model.sourceName)"
            })
            let overflowCount = payload.topModels.count - min(3, payload.topModels.count)
            if overflowCount > 0 {
                lines.append("+\(overflowCount) more safe route summaries")
            }
            if payload.hiddenModelRouteCount > 0 {
                lines.append("\(payload.hiddenModelRouteCount) private route names omitted")
            }
            if !payload.modelRouteCoverageIsComplete {
                lines.append("Model route history is partial")
            }
        }
        lines.append("\(payload.providers.count) sources tracked")
        lines.append(
            "Aggregated locally by CodexBar · No prompts shared · "
                + "Data through \(self.dataThrough(payload.periodEnd))")
        return lines.joined(separator: "\n")
    }
}
