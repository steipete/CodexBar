import CodexBarCore
import Foundation

enum OpenCodeProviderUI {
    @MainActor
    static func cachedCookieTrailingText(provider: UsageProvider, cookieSource: ProviderCookieSource) -> String? {
        guard cookieSource != .manual else { return nil }
        return ProviderCookieSourceUI.cachedTrailingText(provider: provider)
    }
}
