import Foundation

/// API-equivalent token estimates, never Antigravity subscription charges or credit deductions.
enum AntigravityLocalPricing {
    static func costUSD(model: String, event: AntigravityLocalReader.Event) -> Double? {
        // Writes omit cache duration: neither Claude's write TTL nor Gemini storage cost can be inferred.
        guard event.cacheWrite == 0 else { return nil }
        guard let usage = event.turn.usage, let timestamp = event.turn.timestampMs,
              let output = AntigravityLocalReader.checkedAdd(usage.output, usage.reasoning)
        else { return nil }
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000)
        let model = model.lowercased()
        if model.hasPrefix("claude-") {
            let apiModel = model.hasSuffix("-thinking") ? String(model.dropLast("-thinking".count)) : model
            return CostUsagePricing.claudeCostUSD(
                model: apiModel,
                inputTokens: event.input,
                cacheReadInputTokens: usage.cacheRead,
                cacheCreationInputTokens: 0,
                outputTokens: output,
                pricingDate: date,
                modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        }
        // Standard text API rates, verified 2026-09-13. Thinking is billed as output.
        // https://ai.google.dev/gemini-api/docs/pricing
        // These exact IDs share a published introductory price through 2026-12-31.
        // Do not use canonicalModelID here: retired picker tiers route to a successor,
        // which does not establish the price of a historical request to the old model.
        guard ["gemini-3.6-flash", "gemini-3.7-flash", "gemini-3.8-flash"].contains(model)
        else { return nil }
        let introductoryEnd = Date(timeIntervalSince1970: 1_798_761_600) // 2027-01-01 UTC
        let multiplier = date < introductoryEnd ? 1.0 : 2.0
        let cost = (Double(event.input) * 0.75
            + Double(usage.cacheRead) * 0.075
            + Double(output) * 3.75) * multiplier / 1_000_000
        return cost.isFinite ? cost : nil
    }
}
