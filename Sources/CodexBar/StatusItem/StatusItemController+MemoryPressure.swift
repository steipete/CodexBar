import AppKit
import CodexBarCore

extension StatusItemController {
    func trimRebuildableCachesForMemoryPressure() -> MemoryPressureCacheTrimSummary {
        let mergedSwitcherSelectionCount = self.mergedSwitcherContentCaches.values.reduce(0) { total, entries in
            total + entries.count
        }
        let summary = MemoryPressureCacheTrimSummary(
            menuCardHeights: self.menuCardHeightCache.count,
            menuWidths: self.measuredStandardMenuWidthCache.count,
            mergedSwitcherSelections: mergedSwitcherSelectionCount,
            recycledMenuCardViews: self.menuCardViewRecyclePool.count)

        self.menuCardHeightCache.removeAll(keepingCapacity: false)
        self.measuredStandardMenuWidthCache.removeAll(keepingCapacity: false)
        self.mergedSwitcherContentCaches.removeAll(keepingCapacity: false)
        self.menuCardViewRecyclePool.removeAll(keepingCapacity: false)
        self.menuBarLayoutRenderer.removeAll()

        return summary
    }

    #if DEBUG
    func seedRebuildableCachesForMemoryPressureProof() {
        let menu = NSMenu()
        let cacheEntry = CachedMergedSwitcherMenuContent(
            requiredMenuContentVersion: self.menuSession.contentVersion,
            menuWidth: 300,
            codexAccountDisplay: nil,
            tokenAccountDisplay: nil,
            localizationSignature: self.menuLocalizationSignature(),
            items: [])
        self.menuCardHeightCache[
            MenuCardHeightCacheKey(
                id: "debug-memory-pressure-card",
                scope: UsageProvider.codex.rawValue,
                width: 30000,
                textScale: Self.menuCardHeightTextScaleToken(),
                fingerprint: "debug-memory-pressure"),
        ] = 44
        self.measuredStandardMenuWidthCache["debug-memory-pressure-width"] = 300
        self.mergedSwitcherContentCaches[ObjectIdentifier(menu)] = [
            .overview: cacheEntry,
            .provider(.codex): cacheEntry,
        ]
        self.menuCardViewRecyclePool["debug-memory-pressure-card"] = NSView()
    }
    #endif
}
