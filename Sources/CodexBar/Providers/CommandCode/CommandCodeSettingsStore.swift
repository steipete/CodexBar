import CodexBarCore
import Foundation

extension SettingsStore {
    var commandcodeCookieHeader: String {
        get { self[providerConfig: .commandcode, field: .cookieHeader] }
        set { self[providerConfig: .commandcode, field: .cookieHeader] = newValue }
    }

    var commandcodeCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .commandcode, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .commandcode) }
    }
}
