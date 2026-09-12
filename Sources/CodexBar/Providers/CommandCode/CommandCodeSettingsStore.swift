import CodexBarCore
import Foundation

extension SettingsStore {
    var commandcodeCookieHeader: String {
        get { self[providerConfig: .commandcode, field: .cookieHeader] }
        set { self[providerConfig: .commandcode, field: .cookieHeader] = newValue }
    }

    var commandcodeCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .commandcode, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .commandcode) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .commandcode, field: "cookieSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    func commandcodeSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .CommandCodeProviderSettings {
        self.resolvedCookieSettings(
            provider: .commandcode,
            configuredSource: self.commandcodeCookieSource,
            configuredHeader: self.commandcodeCookieHeader,
            tokenOverride: tokenOverride)
    }
}
