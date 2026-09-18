import CodexBarCore
import Foundation

extension SettingsStore {
    var augmentCookieHeader: String {
        get { self[providerConfig: .augment, field: .cookieHeader] }
        set { self[providerConfig: .augment, field: .cookieHeader] = newValue }
    }

    var augmentCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .augment, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .augment) }
    }
}
