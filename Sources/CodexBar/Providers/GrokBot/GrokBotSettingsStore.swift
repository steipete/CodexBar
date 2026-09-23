import CodexBarCore
import Foundation

extension SettingsStore {
    var grokbotCookieHeader: String {
        get { self[providerConfig: .grokbot, field: .cookieHeader] }
        set { self[providerConfig: .grokbot, field: .cookieHeader] = newValue }
    }

    var grokbotCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .grokbot, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .grokbot) }
    }
}
