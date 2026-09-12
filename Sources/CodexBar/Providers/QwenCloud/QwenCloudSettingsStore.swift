import CodexBarCore
import Foundation

extension SettingsStore {
    var qwenCloudCookieHeader: String {
        get { self[providerConfig: .qwencloud, field: .cookieHeader] }
        set { self[providerConfig: .qwencloud, field: .cookieHeader] = newValue }
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
