import CodexBarCore
import Foundation

extension SettingsStore {
    var zoomMateCookieHeader: String {
        get { self[providerConfig: .zoommate, field: .cookieHeader] }
        set { self[providerConfig: .zoommate, field: .cookieHeader] = newValue }
    }

    var zoomMateCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .zoommate, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .zoommate) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .zoommate, field: "cookieSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    func zoomMateSettingsSnapshot(
        tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.ZoomMateProviderSettings
    {
        self.resolvedCookieSettings(
            provider: .zoommate,
            configuredSource: self.zoomMateCookieSource,
            configuredHeader: self.zoomMateCookieHeader,
            tokenOverride: tokenOverride)
    }
}
