import CodexBarCore
import Foundation

extension SettingsStore {
    var mistralCookieHeader: String {
        get { self[providerConfig: .mistral, field: .cookieHeader] }
        set { self[providerConfig: .mistral, field: .cookieHeader] = newValue }
    }

    var mistralCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .mistral, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .mistral) }
    }
}
