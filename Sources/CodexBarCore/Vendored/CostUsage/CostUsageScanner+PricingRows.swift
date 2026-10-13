import Foundation

extension CostUsageScanner {
    static func codexResolvedCostUSD(
        for row: CodexUsageRow,
        priorityTurns: [String: CodexPriorityTurnMetadata] = [:],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?,
        customPricing: CostUsageCustomPricing? = nil,
        pricingResolver: CostUsagePricing.CodexResolver? = nil) -> Double?
    {
        if let authoritativeCostNanos = row.knownCostNanos {
            return Double(authoritativeCostNanos) / self.costScale
        }
        if row.isIncludedInPlan == true { return 0 }
        let isPriority = row.turnID.flatMap { priorityTurns[$0] } != nil || row.pricingMode == "priority"
        let pricedModel = self.codexPricedModel(for: row, priorityTurns: priorityTurns)
        let overlay = customPricing ?? .empty
        let pricingDate = row.timestampUnixMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        let baseCost = CostUsagePricing.codexCostUSD(
            model: pricedModel,
            inputTokens: row.input,
            cachedInputTokens: row.cached,
            outputTokens: row.output,
            pricingDate: pricingDate,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot,
            customPricing: overlay,
            pricingResolver: pricingResolver)
        guard isPriority else { return baseCost }
        guard let priorityCost = CostUsagePricing.codexPriorityCostUSD(
            model: pricedModel,
            inputTokens: row.input,
            cachedInputTokens: row.cached,
            outputTokens: row.output,
            pricingDate: pricingDate,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot,
            customPricing: overlay,
            pricingResolver: pricingResolver)
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

    /// The model whose rates price `row`, as the custom overlay and catalogs look it up.
    static func codexPricedModel(for row: CodexUsageRow, priorityTurns: [String: CodexPriorityTurnMetadata]) -> String {
        row.turnID.flatMap { priorityTurns[$0] }.map { self.codexPriorityPricingModel(for: row, priorityMetadata: $0) }
            ?? row.pricingModel
            ?? row.model
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
