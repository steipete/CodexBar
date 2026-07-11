import Foundation

public struct CursorRequestCostSummary: Codable, Equatable, Sendable {
    public let exactUSD: Decimal?
    public let lowerBoundUSD: Decimal?
    public let upperBoundUSD: Decimal?
    public let containsApproximation: Bool

    public init(
        exactUSD: Decimal?,
        lowerBoundUSD: Decimal?,
        upperBoundUSD: Decimal?,
        containsApproximation: Bool)
    {
        self.exactUSD = exactUSD
        self.lowerBoundUSD = lowerBoundUSD
        self.upperBoundUSD = upperBoundUSD
        self.containsApproximation = containsApproximation
    }
}

public struct CursorRequestCostEstimate: Equatable, Sendable {
    public enum Confidence: String, Equatable, Sendable {
        case exactBreakdown
        case approximateTotalOnly
        case approximateLowerBound
        case partialBreakdownUnavailable
        case unknownModel
        case missingPricing
        case missingBreakdown
    }

    public let usd: Decimal?
    public let lowerBoundUSD: Decimal?
    public let upperBoundUSD: Decimal?
    public let confidence: Confidence
    public let pricingKey: String?
    public let pricingSource: String?
    public let explanation: String

    public init(
        usd: Decimal?,
        lowerBoundUSD: Decimal? = nil,
        upperBoundUSD: Decimal? = nil,
        confidence: Confidence,
        pricingKey: String?,
        pricingSource: String?,
        explanation: String)
    {
        self.usd = usd
        self.lowerBoundUSD = lowerBoundUSD
        self.upperBoundUSD = upperBoundUSD
        self.confidence = confidence
        self.pricingKey = pricingKey
        self.pricingSource = pricingSource
        self.explanation = explanation
    }
}

public enum CursorRequestCostEstimator {
    public static let legacyDisclaimer = "Model-cost estimate only. Cursor legacy quota is request-based."
    public static let claudeCacheAssumption = "Assumes Anthropic 5-minute cache-write pricing."
    public static let composerCacheCaveat =
        "Composer cache tokens count as input-equivalent; no separate Composer cache billing published."

    private static let catalogSource = "CostUsagePricing local catalog (verified 2026-07-11)"

    private struct CursorModelPricing {
        let inputUSDPerToken: Double
        let outputUSDPerToken: Double
        let source: String
    }

    private static let cursorPricing: [String: CursorModelPricing] = [
        "composer-2.5-fast": .init(
            inputUSDPerToken: 3e-6,
            outputUSDPerToken: 15e-6,
            source: "Cursor Composer 2.5 changelog, checked 2026-07-11"),
        "composer-2.5-standard": .init(
            inputUSDPerToken: 0.5e-6,
            outputUSDPerToken: 2.5e-6,
            source: "Cursor Composer 2.5 changelog, checked 2026-07-11"),
    ]

    public static func estimate(for request: CursorRecentRequest) -> CursorRequestCostEstimate {
        self.estimate(model: request.model, tokens: request.tokens, breakdown: request.tokenBreakdown)
    }

    public static func summarizedEstimate(for requests: [CursorRecentRequest]) -> CursorRequestCostSummary? {
        var exact = Decimal.zero
        var lower = Decimal.zero
        var upper = Decimal.zero
        var hasContribution = false
        var hasApproximation = false
        var lowerOnly = false

        for request in requests {
            let estimate = self.estimate(for: request)
            if let usd = estimate.usd {
                exact += usd
                lower += usd
                upper += usd
                hasContribution = true
            } else if let estimateLower = estimate.lowerBoundUSD {
                lower += estimateLower
                if let estimateUpper = estimate.upperBoundUSD {
                    upper += estimateUpper
                } else {
                    lowerOnly = true
                }
                hasApproximation = true
                hasContribution = true
            }
        }

        guard hasContribution else { return nil }
        return CursorRequestCostSummary(
            exactUSD: hasApproximation ? nil : exact,
            lowerBoundUSD: lower,
            upperBoundUSD: lowerOnly ? nil : upper,
            containsApproximation: hasApproximation)
    }

    public static func summedUSD(for requests: [CursorRecentRequest]) -> Decimal? {
        self.summarizedEstimate(for: requests)?.exactUSD
    }

    private static func estimate(
        model: String,
        tokens: Int,
        breakdown: CursorRecentRequestTokenBreakdown?) -> CursorRequestCostEstimate
    {
        let normalized = CursorModelNormalizer.normalize(model)
        guard let pricingKey = normalized.pricingKey else {
            return self.unavailable(.unknownModel, model: model)
        }

        switch normalized.provider {
        case .openai:
            return self.estimateOpenAI(
                pricingKey: pricingKey,
                tokens: tokens,
                breakdown: breakdown)
        case .anthropic:
            return self.estimateAnthropic(
                pricingKey: pricingKey,
                tokens: tokens,
                breakdown: breakdown)
        case .cursor:
            return self.estimateComposer(
                pricingKey: pricingKey,
                tokens: tokens,
                breakdown: breakdown)
        default:
            return self.unavailable(.missingPricing, model: model)
        }
    }

    private static func estimateOpenAI(
        pricingKey: String,
        tokens: Int,
        breakdown: CursorRecentRequestTokenBreakdown?) -> CursorRequestCostEstimate
    {
        guard let capabilities = CostUsagePricing.codexPricingCapabilities(model: pricingKey) else {
            return self.unavailable(.missingPricing, model: pricingKey)
        }
        if let breakdown,
           let input = breakdown.inputTokens,
           let output = breakdown.outputTokens,
           let cacheRead = breakdown.cacheReadTokens
        {
            let cost = CostUsagePricing.codexCostUSD(
                model: pricingKey,
                inputTokens: input,
                cachedInputTokens: cacheRead,
                outputTokens: output)
            return self.exact(cost, pricingKey: pricingKey, source: self.catalogSource)
        }

        let cacheRead = breakdown?.cacheReadTokens ?? 0
        let minimumRate = cacheRead > 0
            ? (capabilities.cacheReadInputCostPerToken ?? capabilities.inputCostPerToken)
            : capabilities.inputCostPerToken
        let lower = Decimal(Double(max(tokens, 0)) * minimumRate)
        let cacheContext = cacheRead > 0 ? "cache-read evidence" : "no cache-read evidence"
        return CursorRequestCostEstimate(
            usd: nil,
            lowerBoundUSD: lower,
            confidence: .approximateLowerBound,
            pricingKey: pricingKey,
            pricingSource: self.catalogSource,
            explanation: "Conservative lower-bound from \(cacheContext); Cursor did not expose a complete "
                + "input/output/cache split. \(Self.legacyDisclaimer)")
    }

    private static func estimateAnthropic(
        pricingKey: String,
        tokens: Int,
        breakdown: CursorRecentRequestTokenBreakdown?) -> CursorRequestCostEstimate
    {
        guard let capabilities = CostUsagePricing.claudePricingCapabilities(model: pricingKey) else {
            return self.unavailable(.missingPricing, model: pricingKey)
        }
        if let breakdown,
           breakdown.confidence == .exactBreakdown,
           let input = breakdown.inputTokens,
           let output = breakdown.outputTokens
        {
            let cost = CostUsagePricing.claudeCostUSD(
                model: pricingKey,
                inputTokens: input,
                cacheReadInputTokens: breakdown.cacheReadTokens ?? 0,
                cacheCreationInputTokens: breakdown.cacheWriteTokens ?? 0,
                outputTokens: output)
            return self.exact(cost, pricingKey: pricingKey, source: self.catalogSource)
        }

        let total = Double(max(tokens, 0))
        return CursorRequestCostEstimate(
            usd: nil,
            lowerBoundUSD: Decimal(total * capabilities.inputCostPerToken),
            upperBoundUSD: Decimal(total * capabilities.outputCostPerToken),
            confidence: .approximateTotalOnly,
            pricingKey: pricingKey,
            pricingSource: self.catalogSource,
            explanation: "Token split unavailable. \(Self.claudeCacheAssumption) \(Self.legacyDisclaimer)")
    }

    private static func estimateComposer(
        pricingKey: String,
        tokens: Int,
        breakdown: CursorRecentRequestTokenBreakdown?) -> CursorRequestCostEstimate
    {
        guard let pricing = self.cursorPricing[pricingKey] else {
            return self.unavailable(.missingPricing, model: pricingKey)
        }
        if let breakdown,
           breakdown.confidence == .exactBreakdown,
           let input = breakdown.inputTokens,
           let output = breakdown.outputTokens
        {
            let inputEquivalent = input + (breakdown.cacheReadTokens ?? 0) + (breakdown.cacheWriteTokens ?? 0)
            let cost = Double(inputEquivalent) * pricing.inputUSDPerToken + Double(output) * pricing.outputUSDPerToken
            return self.exact(cost, pricingKey: pricingKey, source: pricing.source)
        }
        let total = Double(max(tokens, 0))
        return CursorRequestCostEstimate(
            usd: nil,
            lowerBoundUSD: Decimal(total * pricing.inputUSDPerToken),
            upperBoundUSD: Decimal(total * pricing.outputUSDPerToken),
            confidence: .approximateTotalOnly,
            pricingKey: pricingKey,
            pricingSource: pricing.source,
            explanation: "Token split unavailable. \(Self.composerCacheCaveat) \(Self.legacyDisclaimer)")
    }

    private static func exact(_ cost: Double?, pricingKey: String, source: String) -> CursorRequestCostEstimate {
        guard let cost else { return self.unavailable(.missingPricing, model: pricingKey) }
        return CursorRequestCostEstimate(
            usd: Decimal(cost),
            confidence: .exactBreakdown,
            pricingKey: pricingKey,
            pricingSource: source,
            explanation: Self.legacyDisclaimer)
    }

    private static func unavailable(
        _ confidence: CursorRequestCostEstimate.Confidence,
        model: String) -> CursorRequestCostEstimate
    {
        CursorRequestCostEstimate(
            usd: nil,
            confidence: confidence,
            pricingKey: nil,
            pricingSource: nil,
            explanation: "No local price is available for \(model). \(self.legacyDisclaimer)")
    }
}
