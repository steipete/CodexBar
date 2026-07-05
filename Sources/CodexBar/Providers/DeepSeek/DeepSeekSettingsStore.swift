import CodexBarCore
import Foundation

extension SettingsStore {
    var deepSeekCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .deepseek)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .deepseek) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .deepseek, field: "cookieHeader", value: newValue)
        }
    }

    var deepSeekCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .deepseek, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .deepseek) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .deepseek, field: "cookieSource", value: newValue.rawValue)
        }
    }

    var deepSeekUsageDataSource: ProviderSourceMode {
        get { self.configSnapshot.providerConfig(for: .deepseek)?.source ?? .auto }
        set {
            self.updateProviderConfig(provider: .deepseek) { entry in
                entry.source = newValue
            }
            self.logProviderModeChange(provider: .deepseek, field: "usageSource", value: newValue.rawValue)
        }
    }

    func ensureDeepSeekCookieLoaded() {}
}

extension SettingsStore {
    func deepSeekSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
        .DeepSeekProviderSettings
    {
        self.resolvedCookieSettings(
            provider: .deepseek,
            configuredSource: self.deepSeekCookieSource,
            configuredHeader: self.deepSeekCookieHeader,
            tokenOverride: tokenOverride)
    }
}
