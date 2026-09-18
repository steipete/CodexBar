import CodexBarCore
import Foundation

extension SettingsStore {
    var manusManualCookieHeader: String {
        get { self[providerConfig: .manus, field: .cookieHeader] }
        set { self[providerConfig: .manus, field: .cookieHeader] = newValue }
    }

    var manusCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .manus, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .manus) }
    }
}
