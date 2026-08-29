import Foundation

enum CostUsagePricing {
    private static let codexPriorityInputTokenLimit = 272_000
    static let codexUnattributedModel = "unknown"

    struct CodexPricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheReadInputCostPerToken: Double?
        /// Optional cache-write (cache creation) rate. When nil, write tokens are billed at the
        /// uncached input rate (legacy Codex folding behavior).
        let cacheWriteInputCostPerToken: Double?
        let displayLabel: String?

        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?
        let cacheWriteInputCostPerTokenAboveThreshold: Double?

        init(
            inputCostPerToken: Double,
            outputCostPerToken: Double,
            cacheReadInputCostPerToken: Double?,
            displayLabel: String?,
            cacheWriteInputCostPerToken: Double? = nil,
            thresholdTokens: Int? = nil,
            inputCostPerTokenAboveThreshold: Double? = nil,
            outputCostPerTokenAboveThreshold: Double? = nil,
            cacheReadInputCostPerTokenAboveThreshold: Double? = nil,
            cacheWriteInputCostPerTokenAboveThreshold: Double? = nil)
        {
            self.inputCostPerToken = inputCostPerToken
            self.outputCostPerToken = outputCostPerToken
            self.cacheReadInputCostPerToken = cacheReadInputCostPerToken
            self.cacheWriteInputCostPerToken = cacheWriteInputCostPerToken
            self.displayLabel = displayLabel
            self.thresholdTokens = thresholdTokens
            self.inputCostPerTokenAboveThreshold = inputCostPerTokenAboveThreshold
            self.outputCostPerTokenAboveThreshold = outputCostPerTokenAboveThreshold
            self.cacheReadInputCostPerTokenAboveThreshold = cacheReadInputCostPerTokenAboveThreshold
            self.cacheWriteInputCostPerTokenAboveThreshold = cacheWriteInputCostPerTokenAboveThreshold
        }
    }

    struct ClaudePricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheCreationInputCostPerToken: Double
        let cacheReadInputCostPerToken: Double

        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheCreationInputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?
    }

    private struct ClaudeCostTokens {
        let input: Int
        let cacheRead: Int
        let cacheCreation: Int
        let cacheCreation1h: Int
        let output: Int
    }

    private static let codex: [String: CodexPricing] = [
        "gpt-5": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5-codex": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5-mini": CodexPricing(
            inputCostPerToken: 2.5e-7,
            outputCostPerToken: 2e-6,
            cacheReadInputCostPerToken: 2.5e-8,
            displayLabel: nil),
        "gpt-5-nano": CodexPricing(
            inputCostPerToken: 5e-8,
            outputCostPerToken: 4e-7,
            cacheReadInputCostPerToken: 5e-9,
            displayLabel: nil),
        "gpt-5-pro": CodexPricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 1.2e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
        "gpt-5.1": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5.1-codex": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5.1-codex-max": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5.1-codex-mini": CodexPricing(
            inputCostPerToken: 2.5e-7,
            outputCostPerToken: 2e-6,
            cacheReadInputCostPerToken: 2.5e-8,
            displayLabel: nil),
        "gpt-5.2": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7,
            displayLabel: nil),
        "gpt-5.2-codex": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7,
            displayLabel: nil),
        "gpt-5.2-pro": CodexPricing(
            inputCostPerToken: 2.1e-5,
            outputCostPerToken: 1.68e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
        "gpt-5.3-codex": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7,
            displayLabel: nil),
        "gpt-5.3-codex-spark": CodexPricing(
            inputCostPerToken: 0,
            outputCostPerToken: 0,
            cacheReadInputCostPerToken: 0,
            displayLabel: "Research Preview"),
        "gpt-5.4": CodexPricing(
            inputCostPerToken: 2.5e-6,
            outputCostPerToken: 1.5e-5,
            cacheReadInputCostPerToken: 2.5e-7,
            displayLabel: nil,
            thresholdTokens: 272_000,
            inputCostPerTokenAboveThreshold: 5e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheReadInputCostPerTokenAboveThreshold: 5e-7),
        "gpt-5.4-mini": CodexPricing(
            inputCostPerToken: 7.5e-7,
            outputCostPerToken: 4.5e-6,
            cacheReadInputCostPerToken: 7.5e-8,
            displayLabel: nil),
        "gpt-5.4-nano": CodexPricing(
            inputCostPerToken: 2e-7,
            outputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 2e-8,
            displayLabel: nil),
        "gpt-5.4-pro": CodexPricing(
            inputCostPerToken: 3e-5,
            outputCostPerToken: 1.8e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
        "gpt-5.5": CodexPricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 3e-5,
            cacheReadInputCostPerToken: 5e-7,
            displayLabel: nil,
            thresholdTokens: 272_000,
            inputCostPerTokenAboveThreshold: 1e-5,
            outputCostPerTokenAboveThreshold: 4.5e-5,
            cacheReadInputCostPerTokenAboveThreshold: 1e-6),
        "gpt-5.5-pro": CodexPricing(
            inputCostPerToken: 3e-5,
            outputCostPerToken: 1.8e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
        // GPT-5.6 Sol/Terra/Luna (OpenAI pricing page + model cards).
        // Long context: prompts with >272K input tokens are 2x input / 1.5x output for the full
        // request. Cache writes: 1.25x uncached input. API Fast support and multipliers are applied
        // separately after Standard pricing resolves from models.dev or this bundled fallback.
        "gpt-5.6-sol": CodexPricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 3e-5,
            cacheReadInputCostPerToken: 5e-7,
            displayLabel: nil,
            cacheWriteInputCostPerToken: 6.25e-6,
            thresholdTokens: 272_000,
            inputCostPerTokenAboveThreshold: 1e-5,
            outputCostPerTokenAboveThreshold: 4.5e-5,
            cacheReadInputCostPerTokenAboveThreshold: 1e-6,
            cacheWriteInputCostPerTokenAboveThreshold: 1.25e-5),
        "gpt-5.6-terra": CodexPricing(
            inputCostPerToken: 2e-6,
            outputCostPerToken: 1.2e-5,
            cacheReadInputCostPerToken: 2e-7,
            displayLabel: nil,
            cacheWriteInputCostPerToken: 2.5e-6,
            thresholdTokens: 272_000,
            inputCostPerTokenAboveThreshold: 4e-6,
            outputCostPerTokenAboveThreshold: 1.8e-5,
            cacheReadInputCostPerTokenAboveThreshold: 4e-7,
            cacheWriteInputCostPerTokenAboveThreshold: 5e-6),
        "gpt-5.6-luna": CodexPricing(
            inputCostPerToken: 2e-7,
            outputCostPerToken: 1.2e-6,
            cacheReadInputCostPerToken: 2e-8,
            displayLabel: nil,
            cacheWriteInputCostPerToken: 2.5e-7,
            thresholdTokens: 272_000,
            inputCostPerTokenAboveThreshold: 4e-7,
            outputCostPerTokenAboveThreshold: 1.8e-6,
            cacheReadInputCostPerTokenAboveThreshold: 4e-8,
            cacheWriteInputCostPerTokenAboveThreshold: 5e-7),
    ]

    static func codexBuiltInPricingFingerprint() -> String {
        var parts = [
            "priorityInputTokenLimit=\(self.codexPriorityInputTokenLimit)",
            "fastPricingDefinition=api-fast-usd-v1",
        ]
        for model in self.codex.keys.sorted() {
            guard let pricing = self.codex[model] else { continue }
            parts.append([
                "model=\(model)",
                self.optionalPricingFingerprint(pricing.inputCostPerToken),
                self.optionalPricingFingerprint(pricing.outputCostPerToken),
                self.optionalPricingFingerprint(pricing.cacheReadInputCostPerToken),
                self.optionalPricingFingerprint(pricing.cacheWriteInputCostPerToken),
                pricing.displayLabel ?? "nil",
                pricing.thresholdTokens.map(String.init) ?? "nil",
                self.optionalPricingFingerprint(pricing.inputCostPerTokenAboveThreshold),
                self.optionalPricingFingerprint(pricing.outputCostPerTokenAboveThreshold),
                self.optionalPricingFingerprint(pricing.cacheReadInputCostPerTokenAboveThreshold),
                self.optionalPricingFingerprint(pricing.cacheWriteInputCostPerTokenAboveThreshold),
                self.optionalPricingFingerprint(self.codexAPIFastMultiplier(model: model)),
            ].joined(separator: "|"))
        }
        return parts.joined(separator: "\n")
    }

    private static func optionalPricingFingerprint(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.17g", value)
    }

    private static let claude: [String: ClaudePricing] = [
        "claude-fable-5": ClaudePricing(
            inputCostPerToken: 1e-5,
            outputCostPerToken: 5e-5,
            cacheCreationInputCostPerToken: 1.25e-5,
            cacheReadInputCostPerToken: 1e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-haiku-4-5-20251001": ClaudePricing(
            inputCostPerToken: 1e-6,
            outputCostPerToken: 5e-6,
            cacheCreationInputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 1e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-haiku-4-5": ClaudePricing(
            inputCostPerToken: 1e-6,
            outputCostPerToken: 5e-6,
            cacheCreationInputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 1e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-5-20251101": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-5": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-6-20260205": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-6": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-7": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-8": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-5": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
        "claude-sonnet-4-6": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-5-20250929": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
        "claude-opus-4-20250514": ClaudePricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 7.5e-5,
            cacheCreationInputCostPerToken: 1.875e-5,
            cacheReadInputCostPerToken: 1.5e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-1": ClaudePricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 7.5e-5,
            cacheCreationInputCostPerToken: 1.875e-5,
            cacheReadInputCostPerToken: 1.5e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-20250514": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
    ]

    // GPT-5.6 Terra and Luna rates effective before 2026-07-30 (Unix 1785369600).
    // Sol pricing was unchanged. Values from OpenAI pricing page snapshot in PR #2521.
    // Co-authored-by: iam-brain (historical rate values).
    static let codexGPT56PricingCutoff = Date(timeIntervalSince1970: 1_785_369_600)
    private static let codexHistoricalPricing: [String: CodexPricing] = [
        "gpt-5.6-terra": CodexPricing(
            inputCostPerToken: 2.5e-6,
            outputCostPerToken: 1.5e-5,
            cacheReadInputCostPerToken: 2.5e-7,
            displayLabel: nil,
            cacheWriteInputCostPerToken: 3.125e-6,
            thresholdTokens: 272_000,
            inputCostPerTokenAboveThreshold: 5e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheReadInputCostPerTokenAboveThreshold: 5e-7,
            cacheWriteInputCostPerTokenAboveThreshold: 6.25e-6),
        "gpt-5.6-luna": CodexPricing(
            inputCostPerToken: 1e-6,
            outputCostPerToken: 6e-6,
            cacheReadInputCostPerToken: 1e-7,
            displayLabel: nil,
            cacheWriteInputCostPerToken: 1.25e-6,
            thresholdTokens: 272_000,
            inputCostPerTokenAboveThreshold: 2e-6,
            outputCostPerTokenAboveThreshold: 9e-6,
            cacheReadInputCostPerTokenAboveThreshold: 2e-7,
            cacheWriteInputCostPerTokenAboveThreshold: 2.5e-6),
    ]

    private static let claudeFullContextStandardPricingCutoff = Date(timeIntervalSince1970: 1_773_360_000)
    private static let claudeHistoricalLongContext: [String: ClaudePricing] = [
        "claude-opus-4-6": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 1e-5,
            outputCostPerTokenAboveThreshold: 3.75e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 1.25e-5,
            cacheReadInputCostPerTokenAboveThreshold: 1e-6),
        "claude-sonnet-4-6": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
    ]

    static let codexModelsDevProviderID = "openai"
    /// Provider IDs emitted by Codex-compatible clients that have matching entries in models.dev.
    ///
    /// The route prefix is part of the model identity for local usage estimates. Keep both the
    /// client-facing aliases and their models.dev provider IDs here so pricing-cache fingerprints
    /// invalidate when any supported route's rates change.
    static let codexModelsDevProviderIDs: Set<String> = [
        "deepseek",
        "kimi-coding",
        "kimi-for-coding",
        "openai",
        "opencode",
        "opencode-free",
        "opencode-go",
    ]
    private static let claudeModelsDevProviderID = "anthropic"

    /// Returns the provider/model identities that may price a Codex model. Keep this mapping
    /// shared by direct lookup and unknown-price refresh so a newly downloaded catalog is checked
    /// under the same identity that was used to resolve the model.
    static func codexModelsDevPricingTargets(for rawModel: String) -> [(providerID: String, modelID: String)] {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let slash = trimmed.firstIndex(of: "/") {
            let routeID = String(trimmed[..<slash]).lowercased()
            let modelID = String(trimmed[trimmed.index(after: slash)...])
            guard !routeID.isEmpty, !modelID.isEmpty,
                  self.codexModelsDevProviderIDs.contains(routeID)
            else { return [] }

            var providerIDs = [routeID]
            switch routeID {
            case "kimi-coding":
                providerIDs.append("kimi-for-coding")
            case "opencode-free":
                providerIDs.append("opencode")
            default:
                break
            }
            var targets = providerIDs.map { ($0, modelID) }
            if routeID == self.codexModelsDevProviderID {
                let normalized = self.normalizeCodexModel(modelID)
                if normalized != modelID {
                    targets.append((self.codexModelsDevProviderID, normalized))
                }
            }
            return targets
        }

        let normalized = self.normalizeCodexModel(trimmed)
        var targets = [(self.codexModelsDevProviderID, trimmed)]
        if normalized != trimmed {
            targets.append((self.codexModelsDevProviderID, normalized))
        }
        return targets
    }

    static func normalizeCodexModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("openai/") {
            trimmed = String(trimmed.dropFirst("openai/".count))
        }

        // OpenAI routes the unsuffixed gpt-5.6 alias to Sol.
        if trimmed == "gpt-5.6" {
            return "gpt-5.6-sol"
        }

        if self.codex[trimmed] != nil {
            return trimmed
        }

        if let datedSuffix = trimmed.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let base = String(trimmed[..<datedSuffix.lowerBound])
            if self.codex[base] != nil {
                return base
            }
        }
        return trimmed
    }

    static func isCodexUnattributedModel(_ raw: String) -> Bool {
        self.normalizeCodexModel(raw) == self.codexUnattributedModel
    }

    static func codexDisplayLabel(model: String) -> String? {
        let key = self.normalizeCodexModel(model)
        return self.codex[key]?.displayLabel
    }

    static func normalizeClaudeModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("anthropic.") {
            trimmed = String(trimmed.dropFirst("anthropic.".count))
        }

        if let lastDot = trimmed.lastIndex(of: "."),
           trimmed.contains("claude-")
        {
            let tail = String(trimmed[trimmed.index(after: lastDot)...])
            if tail.hasPrefix("claude-") {
                trimmed = tail
            }
        }

        if let vRange = trimmed.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            trimmed.removeSubrange(vRange)
        }

        if let baseRange = trimmed.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(trimmed[..<baseRange.lowerBound])
            if self.claude[base] != nil {
                return base
            }
        }

        return trimmed
    }

    static func customPricingOverlay(fileURL: URL? = nil) -> CostUsageCustomPricing {
        CostUsageCustomPricing.load(fileURL: fileURL)
    }

    static func resolvedCodexPricing(
        model: String,
        pricingDate: Date? = nil,
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> CodexPricing?
    {
        let key = self.normalizeCodexModel(model)
        guard key != self.codexUnattributedModel else { return nil }
        // Use historical bundled rates when the usage predates a known pricing change and
        // no custom overlay or models.dev catalog entry overrides the lookup.
        if let pricingDate,
           pricingDate < self.codexGPT56PricingCutoff,
           let historical = self.codexHistoricalPricing[key]
        {
            return historical
        }
        let modelsDevLookup = self.codexModelsDevLookup(
            model: model,
            catalog: modelsDevCatalog,
            cacheRoot: modelsDevCacheRoot)
        if let lookup = modelsDevLookup {
            let bundled = lookup.pricing.providerID == self.codexModelsDevProviderID ? self.codex[key] : nil
            // A missing catalog context block means models.dev has no long-context opinion, so use
            // the bundled tuple. Once the block exists, preserve its omissions and normal fallback
            // semantics instead of filling individual fields from a different pricing source.
            let bundledLongContext = lookup.pricing.thresholdTokens == nil ? bundled : nil
            let cacheReadAboveThreshold = lookup.pricing.cacheReadInputCostPerTokenAboveThreshold
                ?? (lookup.pricing.thresholdTokens != nil
                    ? lookup.pricing.cacheReadInputCostPerToken
                    ?? lookup.pricing.inputCostPerTokenAboveThreshold
                    ?? lookup.pricing.inputCostPerToken
                    : bundledLongContext?.cacheReadInputCostPerTokenAboveThreshold)
            let cacheWriteAboveThreshold = lookup.pricing.cacheCreationInputCostPerTokenAboveThreshold
                ?? (lookup.pricing.thresholdTokens != nil
                    ? lookup.pricing.cacheCreationInputCostPerToken
                    ?? lookup.pricing.inputCostPerTokenAboveThreshold
                    ?? lookup.pricing.inputCostPerToken
                    : bundledLongContext?.cacheWriteInputCostPerTokenAboveThreshold)
            return CodexPricing(
                inputCostPerToken: lookup.pricing.inputCostPerToken,
                outputCostPerToken: lookup.pricing.outputCostPerToken,
                cacheReadInputCostPerToken: lookup.pricing.cacheReadInputCostPerToken
                    ?? bundled?.cacheReadInputCostPerToken,
                displayLabel: nil,
                cacheWriteInputCostPerToken: lookup.pricing.cacheCreationInputCostPerToken
                    ?? bundled?.cacheWriteInputCostPerToken,
                thresholdTokens: bundled?.thresholdTokens ?? lookup.pricing.thresholdTokens,
                inputCostPerTokenAboveThreshold: lookup.pricing.inputCostPerTokenAboveThreshold
                    ?? bundledLongContext?.inputCostPerTokenAboveThreshold,
                outputCostPerTokenAboveThreshold: lookup.pricing.outputCostPerTokenAboveThreshold
                    ?? bundledLongContext?.outputCostPerTokenAboveThreshold,
                cacheReadInputCostPerTokenAboveThreshold: cacheReadAboveThreshold,
                cacheWriteInputCostPerTokenAboveThreshold: cacheWriteAboveThreshold)
        }

        guard let pricing = self.codex[key] else { return nil }
        return pricing
    }

    /// Resolves the provider-qualified model IDs written by Codex-compatible clients without
    /// falling back to OpenAI pricing for an unrelated route. Unqualified model IDs retain the
    /// historical OpenAI behavior, including the gpt-5.6 alias lookup.
    private static func codexModelsDevLookup(
        model rawModel: String,
        catalog: ModelsDevCatalog?,
        cacheRoot: URL?) -> ModelsDevPricingLookup?
    {
        for target in self.codexModelsDevPricingTargets(for: rawModel) {
            if let lookup = self.modelsDevLookup(
                providerID: target.providerID,
                model: target.modelID,
                catalog: catalog,
                cacheRoot: cacheRoot)
            {
                return lookup
            }
        }
        return nil
    }

    static func codexPriorityCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int = 0,
        cacheWriteInputTokens: Int = 0,
        outputTokens: Int,
        pricingDate: Date? = nil,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil,
        customPricing: CostUsageCustomPricing? = nil) -> Double?
    {
        guard let multiplier = self.codexAPIFastMultiplier(model: model) else { return nil }
        // OpenAI does not support API Fast processing for long-context requests. Do not combine
        // the independent Standard long-context and Fast short-context rate tables.
        if max(0, inputTokens) > self.codexPriorityInputTokenLimit {
            return nil
        }

        return self.codexCostUSD(
            model: model,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens,
            pricingDate: pricingDate,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot,
            customPricing: customPricing)
            .map { $0 * multiplier }
    }

    /// Current public API Fast rates normalized against Standard API pricing. These are deliberately
    /// distinct from ChatGPT/Codex Fast credit multipliers, which do not represent a USD charge.
    static func codexAPIFastMultiplier(model: String) -> Double? {
        switch self.normalizeCodexModel(model) {
        case "gpt-5.4", "gpt-5.4-mini", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna": 2
        case "gpt-5.5": 2.5
        default: nil
        }
    }

    static func codexCostUSD(
        pricing: CodexPricing,
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteInputTokens: Int = 0,
        outputTokens: Int) -> Double
    {
        // Codex/OpenAI reports `input_tokens` as the total prompt size, with cached reads as a
        // SUBSET of it. Cache writes (when tracked separately, e.g. Pi) are also a subset of the
        // non-cached remainder. Clamp so tokens are never invented or double-billed.
        let totalInput = max(0, inputTokens)
        let cached = min(max(0, cachedInputTokens), totalInput)
        let remainingAfterCache = totalInput - cached
        let cacheWrite = min(max(0, cacheWriteInputTokens), remainingAfterCache)
        let nonCached = remainingAfterCache - cacheWrite
        let cachedRate = pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken

        let usesLongContextRates = pricing.thresholdTokens.map { totalInput > $0 } ?? false
        let inputRate = usesLongContextRates
            ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken
            : pricing.inputCostPerToken
        let cachedInputRate = usesLongContextRates
            ? pricing.cacheReadInputCostPerTokenAboveThreshold ?? pricing.cacheReadInputCostPerToken ?? inputRate
            : cachedRate
        let cacheWriteRate = usesLongContextRates
            ? pricing.cacheWriteInputCostPerTokenAboveThreshold
            ?? pricing.cacheWriteInputCostPerToken
            ?? inputRate
            : pricing.cacheWriteInputCostPerToken ?? inputRate
        let outputRate = usesLongContextRates
            ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken
            : pricing.outputCostPerToken

        return (Double(nonCached) * inputRate)
            + (Double(cached) * cachedInputRate)
            + (Double(cacheWrite) * cacheWriteRate)
            + (Double(max(0, outputTokens)) * outputRate)
    }

    static func claudeCostUSD(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        cacheCreationInputTokens1h: Int = 0,
        outputTokens: Int,
        pricingDate: Date? = nil,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> Double?
    {
        let tokens = ClaudeCostTokens(
            input: inputTokens,
            cacheRead: cacheReadInputTokens,
            cacheCreation: cacheCreationInputTokens,
            cacheCreation1h: cacheCreationInputTokens1h,
            output: outputTokens)
        let key = self.normalizeClaudeModel(model)
        if let pricingDate,
           let historicalPricing = self.claudeHistoricalLongContext[key],
           let currentPricing = self.claude[key]
        {
            return self.claudeCostUSD(
                pricing: pricingDate < self.claudeFullContextStandardPricingCutoff
                    ? historicalPricing
                    : currentPricing,
                tokens: tokens)
        }
        if let lookup = self.claudeModelsDevLookup(
            model: model,
            catalog: modelsDevCatalog,
            cacheRoot: modelsDevCacheRoot)
        {
            return self.claudeCostUSD(
                pricing: lookup.pricing,
                tokens: tokens)
        }

        guard let pricing = self.claude[key] else { return nil }
        return self.claudeCostUSD(
            pricing: pricing,
            tokens: tokens)
    }

    private static func claudeCostUSD(
        pricing: ClaudePricing,
        tokens: ClaudeCostTokens) -> Double
    {
        let input = max(0, tokens.input)
        let cacheRead = max(0, tokens.cacheRead)
        let cacheCreationTotal = max(0, tokens.cacheCreation)
        let cacheCreation1h = min(max(0, tokens.cacheCreation1h), cacheCreationTotal)
        let cacheCreation5m = cacheCreationTotal - cacheCreation1h
        let usesLongContextRates = pricing.thresholdTokens.map {
            input + cacheRead + cacheCreationTotal > $0
        } ?? false
        let inputRate = usesLongContextRates
            ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken
            : pricing.inputCostPerToken
        let cacheReadRate = usesLongContextRates
            ? pricing.cacheReadInputCostPerTokenAboveThreshold ?? pricing.cacheReadInputCostPerToken
            : pricing.cacheReadInputCostPerToken
        let cacheCreation5mRate = usesLongContextRates
            ? pricing.cacheCreationInputCostPerTokenAboveThreshold ?? pricing.cacheCreationInputCostPerToken
            : pricing.cacheCreationInputCostPerToken
        let outputRate = usesLongContextRates
            ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken
            : pricing.outputCostPerToken

        return Double(input) * inputRate
            + Double(cacheRead) * cacheReadRate
            + Double(cacheCreation5m) * cacheCreation5mRate
            + Double(cacheCreation1h) * inputRate * 2
            + Double(max(0, tokens.output)) * outputRate
    }

    private static func claudeCostUSD(
        pricing: ModelsDevPricingInfo,
        tokens: ClaudeCostTokens) -> Double
    {
        self.claudeCostUSD(
            pricing: ClaudePricing(
                inputCostPerToken: pricing.inputCostPerToken,
                outputCostPerToken: pricing.outputCostPerToken,
                cacheCreationInputCostPerToken: pricing.cacheCreationInputCostPerToken ?? pricing.inputCostPerToken,
                cacheReadInputCostPerToken: pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken,
                thresholdTokens: pricing.thresholdTokens,
                inputCostPerTokenAboveThreshold: pricing.inputCostPerTokenAboveThreshold,
                outputCostPerTokenAboveThreshold: pricing.outputCostPerTokenAboveThreshold,
                cacheCreationInputCostPerTokenAboveThreshold: pricing.cacheCreationInputCostPerTokenAboveThreshold,
                cacheReadInputCostPerTokenAboveThreshold: pricing.cacheReadInputCostPerTokenAboveThreshold),
            tokens: tokens)
    }

    static func modelsDevCatalog(now: Date = Date(), cacheRoot: URL? = nil) -> ModelsDevCatalog? {
        ModelsDevCache.load(now: now, cacheRoot: cacheRoot).artifact?.catalog
    }

    private static func modelsDevLookup(
        providerID: String,
        model: String,
        catalog: ModelsDevCatalog?,
        cacheRoot: URL?) -> ModelsDevPricingLookup?
    {
        if let catalog {
            return catalog.pricing(providerID: providerID, modelID: model)
        }

        return ModelsDevPricingPipeline.lookup(
            providerID: providerID,
            modelID: model,
            cacheRoot: cacheRoot)
    }
}

extension CostUsagePricing {
    /// Bare Claude-routed IDs may match first-party models.dev vendors. Recognizable model families
    /// stay with their vendor, while unknown bare IDs must have one unambiguous catalog match.
    /// Provider-specific by design: first-party vendor routing for bare Claude model IDs.
    static let claudeFirstPartyModelsDevProviderIDs: [String] = [
        Self.claudeModelsDevProviderID,
        "openai",
        "google",
        "moonshot",
        "kimi-for-coding",
        "minimax",
        "deepseek",
    ]

    static func claudeModelsDevPricingTargets(for rawModel: String) -> [(providerID: String, modelID: String)] {
        var targets = self.claudeUnaliasedModelsDevPricingTargets(for: rawModel)
        // Claude's documented context-window alias stays inside Kimi Code, after every exact route match.
        if targets.contains(where: {
            $0.providerID == "kimi-for-coding"
                && $0.modelID.trimmingCharacters(in: .whitespacesAndNewlines) == "k3[1m]"
        }) {
            targets.append(("kimi-for-coding", "k3"))
        }
        return targets
    }

    private static func claudeUnaliasedModelsDevPricingTargets(
        for rawModel: String) -> [(providerID: String, modelID: String)]
    {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let slash = trimmed.firstIndex(of: "/") {
            let codexTargets = self.codexModelsDevPricingTargets(for: trimmed)
            if !codexTargets.isEmpty {
                return codexTargets
            }

            let routeID = String(trimmed[..<slash]).lowercased()
            let modelID = String(trimmed[trimmed.index(after: slash)...])
            guard !routeID.isEmpty, !modelID.isEmpty,
                  self.claudeFirstPartyModelsDevProviderIDs.contains(routeID)
            else { return [] }
            return self.claudeModelsDevModelIDs(for: modelID).map { (routeID, $0) }
        }

        let providerIDs = self.claudeFirstPartyModelsDevPreferredProviderIDs(for: trimmed)
            ?? self.claudeFirstPartyModelsDevProviderIDs
        let modelIDs = self.claudeModelsDevModelIDs(for: trimmed)
        return providerIDs.flatMap { providerID in
            modelIDs.map { (providerID, $0) }
        }
    }

    private static func claudeModelsDevModelIDs(for rawModel: String) -> [String] {
        let normalized = self.normalizeClaudeModel(rawModel)
        return normalized == rawModel ? [rawModel] : [rawModel, normalized]
    }

    private static func claudeFirstPartyModelsDevPreferredProviderIDs(for rawModel: String) -> [String]? {
        let model = self.normalizeClaudeModel(rawModel).lowercased()
        if model.hasPrefix("claude-") {
            return [self.claudeModelsDevProviderID]
        }
        let openAIReasoningFamily = ["o1", "o3", "o4"].contains {
            model == $0 || model.hasPrefix("\($0)-")
        }
        if openAIReasoningFamily
            || ["gpt-", "chatgpt-", "text-embedding-"].contains(where: model.hasPrefix)
        {
            // Provider-specific by design: recognizable model families stay in their owning first-party catalog.
            return ["openai"]
        }
        if ["gemini-", "gemma-", "deep-research-", "veo-", "lyria-"].contains(where: model.hasPrefix) {
            return ["google"]
        }
        if model == "kimi-for-coding" || model == "k3" || model == "k3[1m]" || model.hasPrefix("k3-") {
            return ["kimi-for-coding"]
        }
        if model.hasPrefix("kimi-") || model.hasPrefix("moonshot-") {
            return ["moonshot", "kimi-for-coding"]
        }
        if model.hasPrefix("minimax-") {
            return ["minimax"]
        }
        if model.hasPrefix("deepseek-") {
            return ["deepseek"]
        }
        return nil
    }

    fileprivate static func claudeModelsDevLookup(
        model rawModel: String,
        catalog: ModelsDevCatalog?,
        cacheRoot: URL?) -> ModelsDevPricingLookup?
    {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExplicitRoute = trimmed.contains("/")
        let hasPreferredVendor = self.claudeFirstPartyModelsDevPreferredProviderIDs(for: trimmed) != nil
        var matches: [ModelsDevPricingLookup] = []
        for target in self.claudeModelsDevPricingTargets(for: rawModel) {
            if let lookup = self.modelsDevLookup(
                providerID: target.providerID,
                model: target.modelID,
                catalog: catalog,
                cacheRoot: cacheRoot)
            {
                if hasExplicitRoute || hasPreferredVendor {
                    return lookup
                }
                matches.append(lookup)
            }
        }
        let matchedProviderIDs = Set(matches.map(\.pricing.providerID))
        guard matchedProviderIDs.count == 1 else { return nil }
        return matches.first
    }
}
