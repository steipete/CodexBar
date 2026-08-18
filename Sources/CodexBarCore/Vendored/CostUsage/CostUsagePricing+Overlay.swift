import Foundation

extension CostUsagePricing {
    static func codexCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        cacheWriteInputTokens: Int = 0,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil,
        customPricing: CostUsageCustomPricing? = nil) -> Double?
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
        modelsDevCacheRoot: URL? = nil,
        customPricing: CostUsageCustomPricing? = nil) -> Double?
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
}
