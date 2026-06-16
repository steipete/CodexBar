import Foundation

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

        return summary
    }
}
