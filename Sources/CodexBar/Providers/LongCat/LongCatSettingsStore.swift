import CodexBarCore
import Foundation

extension SettingsStore {
    var longcatUsageDataSource: ProviderSourceMode {
        get { self.configSnapshot.providerConfig(for: .longcat)?.source ?? .auto }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .web: .web
            case .api, .cli, .oauth: .auto
            }
            self.updateProviderConfig(provider: .longcat) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .longcat, field: "usageSource", value: newValue.rawValue)
        }
    }

    var longcatManualCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .longcat)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .longcat) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .longcat, field: "cookieHeader", value: newValue)
        }
    }

    var longcatCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .longcat, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .longcat) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .longcat, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureLongCatCookieLoaded() {}
}

extension SettingsStore {
    func longcatSettingsSnapshot(tokenOverride: TokenAccountOverride?)
        -> ProviderSettingsSnapshot.LongCatProviderSettings
    {
        self.ensureLongCatCookieLoaded()
        return self.resolvedCookieSettings(
            provider: .longcat,
            configuredSource: self.longcatCookieSource,
            configuredHeader: self.longcatManualCookieHeader,
            tokenOverride: tokenOverride)
    }
}
