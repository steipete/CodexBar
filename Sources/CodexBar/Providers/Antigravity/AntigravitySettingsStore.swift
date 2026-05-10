import CodexBarCore
import Foundation

extension SettingsStore {
    var antigravityUsageDataSource: AntigravityUsageDataSource {
        get {
            let source = self.configSnapshot.providerConfig(for: .antigravity)?.source
            return Self.antigravityUsageDataSource(from: source)
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .oauth: .oauth
            case .cli: .cli
            }
            self.updateProviderConfig(provider: .antigravity) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .antigravity, field: "usageSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    private static func antigravityUsageDataSource(from source: ProviderSourceMode?) -> AntigravityUsageDataSource {
        guard let source else { return .auto }
        switch source {
        case .auto, .web, .api:
            return .auto
        case .oauth:
            return .oauth
        case .cli:
            return .cli
        }
    }
}
