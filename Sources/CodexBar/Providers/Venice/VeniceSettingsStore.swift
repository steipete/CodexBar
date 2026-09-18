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
        get { self.resolvedCookieSource(provider: .venice, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .venice) }
    }

    var veniceCookieHeader: String {
        get { self[providerConfig: .venice, field: .cookieHeader] }
        set { self[providerConfig: .venice, field: .cookieHeader] = newValue }
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
