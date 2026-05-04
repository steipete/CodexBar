import CodexBarCore
import Foundation

extension SettingsStore {
    var zhipuManualCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .zhipu)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .zhipu) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .zhipu, field: "cookieHeader", value: newValue)
        }
    }

    var zhipuCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .zhipu, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .zhipu) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .zhipu, field: "cookieSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    func zhipuSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.ZhipuProviderSettings {
        _ = tokenOverride
        return ProviderSettingsSnapshot.ZhipuProviderSettings(
            cookieSource: self.zhipuCookieSource,
            manualCookieHeader: self.zhipuManualCookieHeader)
    }
}
