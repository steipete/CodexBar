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
        /// Some models publish only standard rates. Do not infer undocumented cache-write or
        /// long-context prices from the standard input rate for those models.
        let allowsCacheWriteInputFallback: Bool
        let requiresExplicitLongContextPricing: Bool
        let hasExplicitLongContextPricing: Bool

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
            cacheWriteInputCostPerTokenAboveThreshold: Double? = nil,
            allowsCacheWriteInputFallback: Bool = true,
            requiresExplicitLongContextPricing: Bool = false,
            hasExplicitLongContextPricing: Bool = false)
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
            self.allowsCacheWriteInputFallback = allowsCacheWriteInputFallback
            self.requiresExplicitLongContextPricing = requiresExplicitLongContextPricing
            self.hasExplicitLongContextPricing = hasExplicitLongContextPricing
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
        // Daybreak aliases may be retargeted. Keep the locally observed canonical Blue model
        // separate for analytics while retaining the complete published Sol pricing tuple.
        "gpt-daybreak-blue-latest": CodexPricing(
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
        // GPT-5.6 Cyber / Daybreak Red. Public rates only; cache-write, long-context,
        // and API Fast are undocumented and stay nil.
        "gpt-5.6-cyber": CodexPricing(
            inputCostPerToken: 1.25e-5,
            outputCostPerToken: 7.5e-5,
            cacheReadInputCostPerToken: 1.25e-6,
            displayLabel: nil,
            allowsCacheWriteInputFallback: false,
            requiresExplicitLongContextPricing: true),
        // Keep the local canonical Red model distinct for analytics. Public documentation has no
        // cache-write, long-context, Priority, or Fast rates for Daybreak Red.
        "gpt-daybreak-red-latest": CodexPricing(
            inputCostPerToken: 1.25e-5,
            outputCostPerToken: 7.5e-5,
            cacheReadInputCostPerToken: 1.25e-6,
            displayLabel: nil,
            allowsCacheWriteInputFallback: false,
            requiresExplicitLongContextPricing: true),
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
                String(pricing.allowsCacheWriteInputFallback),
                String(pricing.requiresExplicitLongContextPricing),
                String(pricing.hasExplicitLongContextPricing),
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

    private static let codexModelsDevProviderID = "openai"
    private static let claudeModelsDevProviderID = "anthropic"

    static func normalizeCodexModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("openai/") {
            trimmed = String(trimmed.dropFirst("openai/".count))
        }

        // OpenAI routes the unsuffixed gpt-5.6 alias to Sol.
        if trimmed == "gpt-5.6" {
            return "gpt-5.6-sol"
        }

        // Unprefixed API aliases resolve to their documented model. The gpt-prefixed names are
        // local Codex canonical identities, retained for separate analytics because aliases may
        // be retargeted.
        switch trimmed {
        case "daybreak-blue-latest":
            return "gpt-5.6-sol"
        case "daybreak-red-latest":
            return "gpt-5.6-cyber"
        default:
            break
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

    static func codexCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        cacheWriteInputTokens: Int = 0,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> Double?
    {
        guard let pricing = self.resolvedCodexPricing(
            model: model,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot)
        else { return nil }
        return self.codexCostUSD(
            pricing: pricing,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens,
            outputTokens: outputTokens)
    }

    static func codexAggregateCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        cacheWriteInputTokens: Int = 0,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> Double?
    {
        guard let pricing = self.resolvedCodexPricing(
            model: model,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot)
        else { return nil }
        if let thresholdTokens = pricing.thresholdTokens,
           max(0, inputTokens) > thresholdTokens
        {
            return nil
        }
        return self.codexCostUSD(
            pricing: pricing,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens,
            outputTokens: outputTokens)
    }

    private static func resolvedCodexPricing(
        model: String,
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> CodexPricing?
    {
        let key = self.normalizeCodexModel(model)
        guard key != self.codexUnattributedModel else { return nil }
        let exactModelsDevLookup = self.modelsDevLookup(
            providerID: self.codexModelsDevProviderID,
            model: model,
            catalog: modelsDevCatalog,
            cacheRoot: modelsDevCacheRoot)
        let modelsDevLookup = exactModelsDevLookup
            ?? (model == key ? nil : self.modelsDevLookup(
                providerID: self.codexModelsDevProviderID,
                model: key,
                catalog: modelsDevCatalog,
                cacheRoot: modelsDevCacheRoot))
        if let lookup = modelsDevLookup {
            let bundled = self.codex[key]
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
            // Models that require documented long-context pricing must not treat one populated
            // dimension as approval to fall back to short-context rates for the remaining buckets.
            let hasExplicitLongContextPricing = lookup.pricing.inputCostPerTokenAboveThreshold != nil
                && lookup.pricing.outputCostPerTokenAboveThreshold != nil
                && lookup.pricing.cacheReadInputCostPerTokenAboveThreshold != nil
                && lookup.pricing.cacheCreationInputCostPerTokenAboveThreshold != nil
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
                cacheWriteInputCostPerTokenAboveThreshold: cacheWriteAboveThreshold,
                allowsCacheWriteInputFallback: lookup.pricing.cacheCreationInputCostPerToken != nil
                    || (bundled?.allowsCacheWriteInputFallback ?? true),
                requiresExplicitLongContextPricing: bundled?.requiresExplicitLongContextPricing ?? false,
                hasExplicitLongContextPricing: hasExplicitLongContextPricing)
        }

        guard let pricing = self.codex[key] else { return nil }
        return pricing
    }

    static func codexPriorityCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int = 0,
        cacheWriteInputTokens: Int = 0,
        outputTokens: Int,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> Double?
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
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot)
            .map { $0 * multiplier }
    }

    /// Current public API Fast rates normalized against Standard API pricing. These are deliberately
    /// distinct from ChatGPT/Codex Fast credit multipliers, which do not represent a USD charge.
    static func codexAPIFastMultiplier(model: String) -> Double? {
        // Keep the local Blue identity ineligible even when usage qualifies it with `openai/`.
        // The public, unprefixed Daybreak alias deliberately normalizes to Sol instead.
        if self.normalizeCodexModel(model) == "gpt-daybreak-blue-latest" {
            return nil
        }
        return switch self.normalizeCodexModel(model) {
        case "gpt-5.4", "gpt-5.4-mini", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna": 2
        case "gpt-5.5": 2.5
        default: nil
        }
    }

    private static func codexCostUSD(
        pricing: CodexPricing,
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteInputTokens: Int = 0,
        outputTokens: Int) -> Double?
    {
        // Codex/OpenAI reports `input_tokens` as the total prompt size, with cached reads as a
        // SUBSET of it. Cache writes (when tracked separately, e.g. Pi) are also a subset of the
        // non-cached remainder. Clamp so tokens are never invented or double-billed.
        let totalInput = max(0, inputTokens)
        let cached = min(max(0, cachedInputTokens), totalInput)
        let remainingAfterCache = totalInput - cached
        let cacheWrite = min(max(0, cacheWriteInputTokens), remainingAfterCache)
        let nonCached = remainingAfterCache - cacheWrite
        if max(0, cacheWriteInputTokens) > 0,
           pricing.cacheWriteInputCostPerToken == nil,
           !pricing.allowsCacheWriteInputFallback
        {
            return nil
        }
        let cachedRate = pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken

        let usesLongContextRates = pricing.thresholdTokens.map { totalInput > $0 } ?? false
        let unsupportedLongContextThreshold = pricing.thresholdTokens ?? self.codexPriorityInputTokenLimit
        if pricing.requiresExplicitLongContextPricing,
           totalInput > unsupportedLongContextThreshold,
           !pricing.hasExplicitLongContextPricing
        {
            return nil
        }
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
        if let lookup = self.modelsDevLookup(
            providerID: self.claudeModelsDevProviderID,
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
