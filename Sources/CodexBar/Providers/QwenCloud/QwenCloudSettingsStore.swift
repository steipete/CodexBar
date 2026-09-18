import CodexBarCore
import Foundation

extension SettingsStore {
    var qwenCloudCookieHeader: String {
        get { self[providerConfig: .qwencloud, field: .cookieHeader] }
        set { self[providerConfig: .qwencloud, field: .cookieHeader] = newValue }
    }

    var qwenCloudCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .qwencloud, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .qwencloud) }
    }
}
