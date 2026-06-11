import CodexBarCore
import Foundation

extension SettingsStore {
    var kimiUsageDataSource: ProviderSourceMode {
        get { self.configSnapshot.providerConfig(for: .kimi)?.source ?? .auto }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .api: .api
            case .web: .web
            case .cli, .oauth: .auto
            }
            self.updateProviderConfig(provider: .kimi) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .kimi, field: "usageSource", value: newValue.rawValue)
        }
    }

    var kimiAPIKey: String {
        get { self.configSnapshot.providerConfig(for: .kimi)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .kimi) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .kimi, field: "apiKey", value: newValue)
        }
    }

    var kimiManualCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .kimi)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .kimi) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .kimi, field: "cookieHeader", value: newValue)
        }
    }

    var kimiCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .kimi, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .kimi) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .kimi, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureKimiAuthTokenLoaded() {}
}

extension SettingsStore {
    func kimiSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.KimiProviderSettings {
        _ = tokenOverride
        self.ensureKimiAuthTokenLoaded()
        return ProviderSettingsSnapshot.KimiProviderSettings(
            cookieSource: self.kimiCookieSource,
            manualCookieHeader: self.kimiManualCookieHeader)
    }
}
