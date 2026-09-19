import CodexBarCore
import Foundation

extension SettingsStore {
    var perplexityManualCookieHeader: String {
        get { self[providerConfig: .perplexity, field: .cookieHeader] }
        set { self[providerConfig: .perplexity, field: .cookieHeader] = newValue }
    }

    var perplexityCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .perplexity, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .perplexity) }
    }
}
