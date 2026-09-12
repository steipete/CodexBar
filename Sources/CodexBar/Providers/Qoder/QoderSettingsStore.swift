import CodexBarCore
import Foundation

extension SettingsStore {
    var qoderCookieHeader: String {
        get { self[providerConfig: .qoder, field: .cookieHeader] }
        set { self[providerConfig: .qoder, field: .cookieHeader] = newValue }
    }

    var qoderCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .qoder, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .qoder) }
    }
}
