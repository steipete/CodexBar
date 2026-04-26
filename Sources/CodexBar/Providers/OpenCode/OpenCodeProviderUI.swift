import CodexBarCore
import Foundation

enum OpenCodeProviderUI {
    @MainActor
    static func cachedCookieTrailingText(provider: UsageProvider, cookieSource: ProviderCookieSource) -> String? {
        guard cookieSource != .manual else { return nil }
        guard let entry = CookieHeaderCache.load(provider: provider) else { return nil }
        let when = entry.storedAt.relativeDescription()
        return "Cached: \(entry.sourceLabel) • \(when)"
    }
}
