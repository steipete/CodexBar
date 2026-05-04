import CodexBarCore
import Foundation

extension SettingsStore {
    var doubaoManualCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .doubao)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .doubao) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .doubao, field: "cookieHeader", value: newValue)
        }
    }

    var doubaoCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .doubao, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .doubao) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .doubao, field: "cookieSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    func doubaoSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.DoubaoProviderSettings {
        _ = tokenOverride
        return ProviderSettingsSnapshot.DoubaoProviderSettings(
            cookieSource: self.doubaoCookieSource,
            manualCookieHeader: self.doubaoManualCookieHeader)
    }
}
