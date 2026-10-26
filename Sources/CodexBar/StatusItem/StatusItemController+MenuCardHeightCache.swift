import AppKit

extension StatusItemController {
    struct MenuCardHeightCacheKey: Hashable {
        let id: String
        let scope: String
        let width: Int
        let textScale: Int
        let fingerprint: String
    }

    /// Measured card height also depends on the resolved font sizes, which the menu cards
    /// derive from semantic text styles (`.body`, `.footnote`, …). Those scale with the
    /// macOS system text-size / Dynamic Type setting, which is neither part of the content
    /// fingerprint nor invalidated on rebuild. Fold the current resolved scale into the key
    /// so a runtime text-size change forces a fresh measurement instead of returning a
    /// height measured at the old scale (clipped / over-tall cards).
    static func menuCardHeightTextScaleToken() -> Int {
        Int((NSFont.preferredFont(forTextStyle: .body).pointSize * 100).rounded())
    }

    func cachedMenuCardHeight(
        for id: String,
        scope: String,
        width: CGFloat,
        fingerprint: String? = nil,
        measure: () -> CGFloat) -> CGFloat
    {
        let key = MenuCardHeightCacheKey(
            id: id,
            scope: scope,
            width: Int((width * 100).rounded()),
            textScale: Self.menuCardHeightTextScaleToken(),
            fingerprint: fingerprint ?? "version:\(self.menuSession.contentVersion)")
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

    func pruneVersionScopedMenuCardHeightCache() {
        let currentVersionFingerprint = "version:\(self.menuSession.contentVersion)"
        for key in self.menuCardHeightCache.keys
            where key.fingerprint.hasPrefix("version:") && key.fingerprint != currentVersionFingerprint
        {
            self.menuCardHeightCache.removeValue(forKey: key)
        }
    }
}
