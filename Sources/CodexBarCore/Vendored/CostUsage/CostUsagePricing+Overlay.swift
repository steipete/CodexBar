import Foundation

extension CostUsagePricing {
    static func codexCostUSD(
        aggregate: Bool = false,
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        cacheWriteInputTokens: Int = 0,
        pricingDate: Date? = nil,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil,
        customPricing: CostUsageCustomPricing? = nil,
        pricingResolver: CodexResolver? = nil) -> Double?
    {
        let overlay = customPricing ?? self.customPricingOverlay()
        if overlay.rates(providerID: self.codexModelsDevProviderID, model: model) != nil {
            return overlay.estimatedCodexCostUSD(
                model: model,
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens,
                cacheWriteInputTokens: cacheWriteInputTokens)
        }
        guard let pricing = self.resolvedCodexPricing(
            model: model,
            pricingDate: pricingDate,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot,
            pricingResolver: pricingResolver)
        else { return nil }
        if aggregate,
           let thresholdTokens = pricing.thresholdTokens,
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
}
