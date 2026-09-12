import CodexBarCore
import Foundation

extension SettingsStore {
    var t3ChatCookieHeader: String {
        get { self[providerConfig: .t3chat, field: .cookieHeader] }
        set { self[providerConfig: .t3chat, field: .cookieHeader] = newValue }
    }

    var t3ChatCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .t3chat, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .t3chat) }
    }
}
