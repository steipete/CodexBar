import CodexBarCore
import Foundation

extension SettingsStore {
    var commandcodeUsageDataSource: ProviderSourceMode {
        get { self.configSnapshot.providerConfig(for: .commandcode)?.source ?? .auto }
        set {
            self.updateProviderConfig(provider: .commandcode) { entry in
                entry.source = newValue == .auto ? nil : newValue
            }
            self.logProviderModeChange(provider: .commandcode, field: "source", value: newValue.rawValue)
        }
    }

    var commandcodeAPIKey: String {
        get { self[providerConfig: .commandcode, field: .apiKey] }
        set { self[providerConfig: .commandcode, field: .apiKey] = newValue }
    }

    var commandcodeCookieHeader: String {
        get { self[providerConfig: .commandcode, field: .cookieHeader] }
        set { self[providerConfig: .commandcode, field: .cookieHeader] = newValue }
    }

    var commandcodeCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .commandcode, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .commandcode) }
    }
}
