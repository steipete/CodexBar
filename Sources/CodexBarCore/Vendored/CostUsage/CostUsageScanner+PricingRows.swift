import Foundation

extension CostUsageScanner {
    static func codexResolvedCostUSD(
        for row: CodexUsageRow,
        priorityTurns: [String: CodexPriorityTurnMetadata] = [:],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?,
        customPricing: CostUsageCustomPricing? = nil) -> Double?
    {
        if let authoritativeCostNanos = row.knownCostNanos {
            return Double(authoritativeCostNanos) / self.costScale
        }
        let priorityMetadata = row.turnID.flatMap { priorityTurns[$0] }
        let isPriority = priorityMetadata != nil || row.pricingMode == "priority"
        let pricedModel = priorityMetadata.map { self.codexPriorityPricingModel(for: row, priorityMetadata: $0) }
            ?? row.pricingModel
            ?? row.model
        let overlay = customPricing ?? .empty
        let pricingDate = row.timestampUnixMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        // Rows store output exclusive of reasoning (tokscale parity); OpenAI bills reasoning at
        // the output rate, so add the subset back before pricing. USD matches the previous
        // inclusive-output behavior exactly.
        let billableOutputTokens = row.output + (row.reasoning ?? 0)
        let baseCost = CostUsagePricing.codexCostUSD(
            model: pricedModel,
            inputTokens: row.input,
            cachedInputTokens: row.cached,
            outputTokens: billableOutputTokens,
            pricingDate: pricingDate,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot,
            customPricing: overlay)
        guard isPriority else { return baseCost }
        guard let priorityCost = CostUsagePricing.codexPriorityCostUSD(
            model: pricedModel,
            inputTokens: row.input,
            cachedInputTokens: row.cached,
            outputTokens: billableOutputTokens,
            pricingDate: pricingDate,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot,
            customPricing: overlay)
        else { return baseCost }
        return max(priorityCost, baseCost ?? priorityCost)
    }

    static func codexResolvedCostNanos(
        for row: CodexUsageRow,
        priorityTurns: [String: CodexPriorityTurnMetadata] = [:],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?,
        customPricing: CostUsageCustomPricing? = nil) -> Int64?
    {
        guard let cost = self.codexResolvedCostUSD(
            for: row,
            priorityTurns: priorityTurns,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot,
            customPricing: customPricing)
        else { return nil }
        let nanos = cost * self.costScale
        guard nanos.isFinite, nanos >= Double(Int64.min), nanos <= Double(Int64.max) else { return nil }
        return Int64(nanos.rounded())
    }

    static func codexRowsForReadTimePricing(_ usage: CostUsageFileUsage) -> [CodexUsageRow] {
        if let rows = usage.codexRows, !rows.isEmpty {
            return rows
        }
        return usage.days.flatMap { day, models in
            models.map { model, packed in
                CodexUsageRow(
                    day: day,
                    model: model,
                    turnID: nil,
                    eventIndex: nil,
                    input: packed[safe: 0] ?? 0,
                    cached: packed[safe: 1] ?? 0,
                    output: packed[safe: 2] ?? 0,
                    knownCostNanos: usage.codexCostNanos?[day]?[model],
                    pricingModel: model,
                    pricingMode: usage.codexPriorityTokens?[day]?[model] == nil ? "standard" : "priority")
            }
        }
    }

    static func codexPriorityPricingModel(
        for row: CodexUsageRow,
        priorityMetadata: CodexPriorityTurnMetadata) -> String
    {
        guard let model = priorityMetadata.model,
              CostUsagePricing.codexAPIFastMultiplier(model: model) != nil
        else { return row.model }
        return model
    }
}
