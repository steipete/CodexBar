import CodexBarCore
import Foundation

extension SettingsStore {
    var kiloUsageDataSource: KiloUsageDataSource {
        get {
            let source = self.configSnapshot.providerConfig(for: .kilo)?.source
            return Self.kiloUsageDataSource(from: source)
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .api: .api
            case .cli: .cli
            }
            self.updateProviderConfig(provider: .kilo) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .kilo, field: "usageSource", value: newValue.rawValue)
        }
    }

    var kiloExtrasEnabled: Bool {
        get {
            guard self.kiloUsageDataSource == .auto else { return false }
            return self.kiloExtrasEnabledRaw
        }
        set {
            self.kiloExtrasEnabledRaw = newValue
        }
    }

    var kiloAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .kilo)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .kilo) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .kilo, field: "apiKey", value: newValue)
        }
    }

    private var kiloExtrasEnabledRaw: Bool {
        get { self.configSnapshot.providerConfig(for: .kilo)?.extrasEnabled ?? false }
        set {
            self.updateProviderConfig(provider: .kilo) { entry in
                entry.extrasEnabled = newValue
            }
            self.logProviderModeChange(
                provider: .kilo,
                field: "extrasEnabled",
                value: newValue ? "1" : "0")
        }
    }
}

extension SettingsStore {
    func kiloSettingsSnapshot(tokenOverride _: TokenAccountOverride?) -> ProviderSettingsSnapshot.KiloProviderSettings {
        ProviderSettingsSnapshot.KiloProviderSettings(
            usageDataSource: self.kiloUsageDataSource,
            extrasEnabled: self.kiloExtrasEnabled)
    }

    private static func kiloUsageDataSource(from source: ProviderSourceMode?) -> KiloUsageDataSource {
        guard let source else { return .auto }
        switch source {
        case .auto, .web, .oauth:
            return .auto
        case .api:
            return .api
        case .cli:
            return .cli
        }
    }
}
