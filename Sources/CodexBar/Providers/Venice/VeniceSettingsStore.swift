import CodexBarCore
import Foundation

extension SettingsStore {
    var veniceUsageDataSource: VeniceUsageDataSource {
        get {
            let source = self.configSnapshot.providerConfig(for: .venice)?.source
            return Self.veniceUsageDataSource(from: source)
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .api: .api
            case .web: .web
            }
            self.updateProviderConfig(provider: .venice) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .venice, field: "usageSource", value: newValue.rawValue)
        }
    }

    var veniceCookieSource: ProviderCookieSource {
        self.resolvedCookieSource(provider: .venice, fallback: .auto)
    }

    var veniceCookieHeader: String {
        self.configSnapshot.providerConfig(for: .venice)?.sanitizedCookieHeader ?? ""
    }

    func veniceSettingsSnapshot(tokenOverride: TokenAccountOverride?)
        -> ProviderSettingsSnapshot.VeniceProviderSettings
    {
        self.resolvedCookieSettings(
            provider: .venice,
            configuredSource: self.veniceCookieSource,
            configuredHeader: self.veniceCookieHeader,
            tokenOverride: tokenOverride)
    }

    private static func veniceUsageDataSource(from source: ProviderSourceMode?) -> VeniceUsageDataSource {
        guard let source else { return .auto }
        switch source {
        case .auto:
            return .auto
        case .api:
            return .api
        case .web:
            return .web
        case .cli, .oauth:
            return .auto
        }
    }
}
