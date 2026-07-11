import CodexBarCore
import Foundation

extension SettingsStore {
    var factoryUsageDataSource: ProviderSourceMode {
        get {
            switch self.configSnapshot.providerConfig(for: .factory)?.source {
            case .api: .api
            case .web: .web
            case .auto, .cli, .oauth, .none: .auto
            }
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .api: .api
            case .web: .web
            case .cli, .oauth: .auto
            }
            self.updateProviderConfig(provider: .factory) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .factory, field: "usageSource", value: newValue.rawValue)
        }
    }

    var factoryAPIKey: String {
        get { self.configSnapshot.providerConfig(for: .factory)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .factory) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .factory, field: "apiKey", value: newValue)
        }
    }

    var factoryCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .factory)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .factory) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .factory, field: "cookieHeader", value: newValue)
        }
    }

    var factoryCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .factory, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .factory) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .factory, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureFactoryCookieLoaded() {}
}

extension SettingsStore {
    func factorySettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .FactoryProviderSettings {
        self.resolvedCookieSettings(
            provider: .factory,
            configuredSource: self.factoryCookieSource,
            configuredHeader: self.factoryCookieHeader,
            tokenOverride: tokenOverride)
    }
}
