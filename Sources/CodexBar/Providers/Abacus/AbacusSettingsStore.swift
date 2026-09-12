import CodexBarCore
import Foundation

extension SettingsStore {
    var abacusCookieHeader: String {
        get { self[providerConfig: .abacus, field: .cookieHeader] }
        set { self[providerConfig: .abacus, field: .cookieHeader] = newValue }
    }

    var abacusCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .abacus, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .abacus) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .abacus, field: "cookieSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    func abacusSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .AbacusProviderSettings {
        self.resolvedCookieSettings(
            provider: .abacus,
            configuredSource: self.abacusCookieSource,
            configuredHeader: self.abacusCookieHeader,
            tokenOverride: tokenOverride)
    }
}
