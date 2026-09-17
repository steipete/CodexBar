import Foundation

enum OpenCodexUsagePricing {
    static func targets(for entry: OpenCodexUsageEntry) -> [ModelsDevPricingTarget] {
        let provider = self.providerID(for: entry)
        let targets = ModelsDevPricingTargetResolver.targets(providerID: provider, modelID: entry.model)
        guard let first = targets.first,
              first.providerID == CostUsagePricing.codexModelsDevProviderID,
              !first.modelID.contains("/")
        else { return targets }
        return CostUsagePricing.codexModelsDevPricingTargets(for: first.modelID).map {
            ModelsDevPricingTarget(providerID: $0.providerID, modelID: $0.modelID)
        }
    }

    static func providerID(for entry: OpenCodexUsageEntry) -> String {
        let provider = entry.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Legacy OpenCodex logs used openai as the transport label for explicit subscription routes.
        // Preserve those routes, but never interpret a router's model namespace as its billing provider.
        if provider == "openai",
           let slash = entry.model.firstIndex(of: "/")
        {
            let prefix = String(entry.model[..<slash]).lowercased()
            if CostUsagePricing.codexModelsDevProviderIDs.contains(prefix) { return prefix }
        }
        return provider
    }
}

extension OpenCodexUsageStore {
    /// Fresh-load refresh only. Cached snapshots remain synchronous and never start network work.
    public static func refreshPricingIfNeeded(entries: [OpenCodexUsageEntry], now: Date) async {
        guard !TestProcessSafety.isRunning else { return }
        await self.refreshPricingIfNeeded(entries: entries, now: now, cacheRoot: nil, client: ModelsDevClient())
    }

    static func refreshPricingIfNeeded(
        entries: [OpenCodexUsageEntry],
        now: Date,
        cacheRoot: URL?,
        client: ModelsDevClient) async
    {
        let targets = Set(entries.filter {
            $0.timestamp <= now && ($0.usageStatus == .reported || $0.usageStatus == .estimated)
        }.flatMap { OpenCodexUsagePricing.targets(for: $0) })
        guard !targets.isEmpty, !Task.isCancelled else { return }
        await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: cacheRoot, client: client)
        let grouped = Dictionary(grouping: targets, by: \.providerID)
        for providerID in grouped.keys.sorted() {
            guard !Task.isCancelled else { return }
            _ = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
                providerID: providerID,
                modelIDs: Set(grouped[providerID, default: []].map(\.modelID)),
                exactModelIDs: true,
                now: now,
                cacheRoot: cacheRoot,
                client: client)
        }
    }
}
