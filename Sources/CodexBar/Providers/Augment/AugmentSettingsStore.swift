import CodexBarCore
import Foundation

extension SettingsStore {
    var augmentCookieHeader: String {
        get { self[providerConfig: .augment, field: .cookieHeader] }
        set { self[providerConfig: .augment, field: .cookieHeader] = newValue }
    }

    var augmentCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .augment, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .augment) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .augment, field: "cookieSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    func augmentSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .AugmentProviderSettings {
        self.resolvedCookieSettings(
            provider: .augment,
            configuredSource: self.augmentCookieSource,
            configuredHeader: self.augmentCookieHeader,
            tokenOverride: tokenOverride)
    }
}
