import CodexBarCore
import Foundation

extension SettingsStore {
    var replicateCookieHeader: String {
        get { self[providerConfig: .replicate, field: .cookieHeader] }
        set { self[providerConfig: .replicate, field: .cookieHeader] = newValue }
    }

    var replicateCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .replicate, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .replicate) }
    }
}
