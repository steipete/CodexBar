import CodexBarCore
import Foundation

extension SettingsStore {
    var miMoCookieHeader: String {
        get { self[providerConfig: .mimo, field: .cookieHeader] }
        set { self[providerConfig: .mimo, field: .cookieHeader] = newValue }
    }

    var miMoCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .mimo, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .mimo) }
    }
}
