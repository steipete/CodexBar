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
        get { self[providerConfig: .kimi, field: .apiKey] }
        set { self[providerConfig: .kimi, field: .apiKey] = newValue }
    }

    var kimiManualCookieHeader: String {
        get { self[providerConfig: .kimi, field: .cookieHeader] }
        set { self[providerConfig: .kimi, field: .cookieHeader] = newValue }
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
}

extension SettingsStore {
    func kimiSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.KimiProviderSettings {
        self.resolvedCookieSettings(
            provider: .kimi,
            configuredSource: self.kimiCookieSource,
            configuredHeader: self.kimiManualCookieHeader,
            tokenOverride: tokenOverride)
    }
}
