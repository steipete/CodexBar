import CodexBarCore
import Foundation

extension SettingsStore {
    var abacusCookieHeader: String {
        get { self[providerConfig: .abacus, field: .cookieHeader] }
        set { self[providerConfig: .abacus, field: .cookieHeader] = newValue }
    }

    var abacusCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .abacus, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .abacus) }
    }
}
