import Foundation
import Testing
@testable import CodexBarCore

/// The promo expiry label is hardcoded English (`"… bonus · exp. …"`) and the bundled Perplexity plugin formats
/// the same value with `toLocaleDateString("en-US", …)`. If the formatter loses its explicit locale it silently
/// falls back to `Locale.current`, which only diverges on non-English hosts — so parity coverage alone passes
/// before and after the regression on an English runner. These assertions hold on every host.
struct PerplexityPromoExpiryLocaleTests {
    @Test
    func `promo expiry formatter stays pinned to POSIX English`() {
        #expect(PerplexityUsageSnapshot.promoExpiryFormatter.locale.identifier == "en_US_POSIX")
    }

    @Test
    func `promo expiry renders an English month regardless of host locale`() {
        // 2026-01-15T12:00:00Z. The formatter keeps the host time zone, so this sits far enough from both
        // month boundaries to stay in January from UTC-12 through UTC+14.
        let expiry = Date(timeIntervalSince1970: 1_768_478_400)
        let rendered = PerplexityUsageSnapshot.promoExpiryFormatter.string(from: expiry)

        #expect(rendered.hasPrefix("Jan"))
        // Guards the specific regression: a `Locale.current` fallback emits digits plus a localized month
        // marker (for example `1월`) instead of an ASCII month abbreviation.
        let isASCIIOnly = rendered.unicodeScalars.allSatisfy(\.isASCII)
        #expect(isASCIIOnly)
    }
}
