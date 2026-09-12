import CodexBarCore
import Foundation

extension SettingsStore {
    var cursorCookieHeader: String {
        get { self[providerConfig: .cursor, field: .cookieHeader] }
        set { self[providerConfig: .cursor, field: .cookieHeader] = newValue }
    }

    var cursorCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .cursor, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .cursor) }
    }
}
