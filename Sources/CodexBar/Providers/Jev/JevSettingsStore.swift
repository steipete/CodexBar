import CodexBarCore
import Foundation

extension SettingsStore {
    var jevCookieHeader: String {
        get { self[providerConfig: .jev, field: .cookieHeader] }
        set { self[providerConfig: .jev, field: .cookieHeader] = newValue }
    }

    var jevCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .jev, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .jev) }
    }
}
