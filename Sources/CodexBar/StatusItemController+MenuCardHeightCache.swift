import AppKit

// === LAYOUT ENGINE CONTRACT (PHASE C) ===
// Height measurement is a deterministic function of:
//   1. contentFingerprint — hash of the data shaping the card (model fields, account state)
//   2. width             — the resolved menu rendering width (×100, integer-quantized)
//   3. textScale         — system text-size token at measurement time
//   4. providerState     — provider/identity scope (provider.rawValue, account.id, etc.)
// `id` identifies a specific card slot so two cards with identical content get
// independent entries. Same key → same height, no recomputation. Key change →
// forced re-measurement in the next C-phase.

extension StatusItemController {
    struct MenuCardHeightCacheKey: Hashable {
        let id: String // card slot identifier
        let providerState: String // provider / account / scope
        let width: Int // menu width × 100
        let textScale: Int // system text-size token
        let contentFingerprint: String // hash of content payload
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

    /// === PHASE C: LAYOUT ENGINE — DETERMINISTIC HEIGHT LOOKUP ===
    /// Same (id, providerState, width, textScale, contentFingerprint) → identical height.
    /// The cache is the source of truth for C-phase measurement output. A-phase
    /// render-layer callers MUST NOT invoke this — height is finalized at C-phase exit.
    func cachedMenuCardHeight(
        for id: String,
        providerState: String,
        width: CGFloat,
        contentFingerprint: String? = nil,
        measure: () -> CGFloat) -> CGFloat
    {
        let key = MenuCardHeightCacheKey(
            id: id,
            providerState: providerState,
            width: Int((width * 100).rounded()),
            textScale: Self.menuCardHeightTextScaleToken(),
            contentFingerprint: contentFingerprint ?? "version:\(self.menuContentVersion)")
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
        let currentVersionFingerprint = "version:\(self.menuContentVersion)"
        for key in self.menuCardHeightCache.keys
            where key.contentFingerprint.hasPrefix("version:") && key.contentFingerprint != currentVersionFingerprint
        {
            self.menuCardHeightCache.removeValue(forKey: key)
        }
    }
}
