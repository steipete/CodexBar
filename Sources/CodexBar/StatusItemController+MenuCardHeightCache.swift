import AppKit

extension StatusItemController {
    struct MenuCardHeightCacheKey: Hashable {
        let id: String
        let width: Int
        let version: Int
    }

    func cachedMenuCardHeight(for id: String, width: CGFloat, measure: () -> CGFloat) -> CGFloat {
        let key = MenuCardHeightCacheKey(
            id: id,
            width: Int((width * 100).rounded()),
            version: self.menuContentVersion)
        if let cached = self.menuCardHeightCache[key] {
            return cached
        }
        let height = measure()
        if self.menuCardHeightCache.count > 256 {
            self.menuCardHeightCache.removeAll(keepingCapacity: true)
        }
        self.menuCardHeightCache[key] = height
        return height
    }
}
