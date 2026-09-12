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
        get { self[providerConfig: .factory, field: .apiKey] }
        set { self[providerConfig: .factory, field: .apiKey] = newValue }
    }

    var factoryCookieHeader: String {
        get { self[providerConfig: .factory, field: .cookieHeader] }
        set { self[providerConfig: .factory, field: .cookieHeader] = newValue }
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
