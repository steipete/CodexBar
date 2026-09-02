import Foundation

extension CostUsagePricing {
    static func modelProvider(
        for model: String,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> CostUsageAttribution.ModelProvider
    {
        if self.isBundledOpenAIModel(model) {
            return .openAI
        }

        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("gemini-") {
            return .google
        }

        if let providerID = self.claudeModelsDevResolvedProviderID(
            model: model,
            catalog: modelsDevCatalog,
            cacheRoot: modelsDevCacheRoot)
        {
            // Provider-specific by design: resolved catalog ownership maps known first-party providers
            // into attribution buckets.
            return switch providerID.lowercased() {
            case "anthropic": .anthropic
            case "openai": .openAI
            case "google": .google
            default: .other
            }
        }

        if self.claudeCostUSD(
            model: model,
            inputTokens: 0,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot) != nil
        {
            return .anthropic
        }

        return .unknown
    }
}
