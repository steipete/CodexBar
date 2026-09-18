import CodexBarCore
import Foundation

extension SettingsStore {
    var zoomMateCookieHeader: String {
        get { self[providerConfig: .zoommate, field: .cookieHeader] }
        set { self[providerConfig: .zoommate, field: .cookieHeader] = newValue }
    }

    var zoomMateCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .zoommate, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .zoommate) }
    }
}
