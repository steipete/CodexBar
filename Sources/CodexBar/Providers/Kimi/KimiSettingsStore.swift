import CodexBarCore
import Foundation

extension SettingsStore {
    var kimiUsageDataSource: KimiUsageDataSource {
        get {
            let source = self.configSnapshot.providerConfig(for: .kimi)?.source
            return Self.kimiUsageDataSource(from: source)
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .oauth: .oauth
            case .api: .api
            }
            self.updateProviderConfig(provider: .kimi) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .kimi, field: "usageSource", value: newValue.rawValue)
        }
    }

    var kimiAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .kimi)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .kimi) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .kimi, field: "apiKey", value: newValue)
        }
    }

    func ensureKimiAPIKeyLoaded() {}
}

extension SettingsStore {
    func kimiSettingsSnapshot(tokenOverride _: TokenAccountOverride?) -> ProviderSettingsSnapshot.KimiProviderSettings {
        ProviderSettingsSnapshot.KimiProviderSettings(usageDataSource: self.kimiUsageDataSource)
    }

    private static func kimiUsageDataSource(from source: ProviderSourceMode?) -> KimiUsageDataSource {
        guard let source else { return .auto }
        switch source {
        case .auto, .web, .cli:
            return .auto
        case .oauth:
            return .oauth
        case .api:
            return .api
        }
    }
}
