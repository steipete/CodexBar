import CodexBarCore
import Foundation

extension SettingsStore {
    var t3ChatCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .t3chat)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .t3chat) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .t3chat, field: "cookieHeader", value: newValue)
        }
    }

    var t3ChatCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .t3chat, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .t3chat) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .t3chat, field: "cookieSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    func t3ChatSettingsSnapshot(
        tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.T3ChatProviderSettings
    {
        self.resolvedCookieSettings(
            provider: .t3chat,
            configuredSource: self.t3ChatCookieSource,
            configuredHeader: self.t3ChatCookieHeader,
            tokenOverride: tokenOverride)
    }
}
