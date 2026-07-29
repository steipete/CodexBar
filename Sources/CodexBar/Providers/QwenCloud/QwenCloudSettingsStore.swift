import CodexBarCore
import Foundation

extension SettingsStore {
    var qwenCloudCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .qwencloud)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .qwencloud) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .qwencloud, field: "cookieHeader", value: newValue)
        }
    }

    var qwenCloudCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .qwencloud, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .qwencloud) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .qwencloud, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func qwenCloudSettingsSnapshot() -> ProviderSettingsSnapshot.QwenCloudProviderSettings {
        ProviderSettingsSnapshot.QwenCloudProviderSettings(
            cookieSource: self.qwenCloudCookieSource,
            manualCookieHeader: self.qwenCloudCookieHeader)
    }
}
