import CodexBarCore
import Foundation

extension SettingsStore {
    var helmcodeCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .helmcode)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .helmcode) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .helmcode, field: "cookieHeader", value: newValue)
        }
    }

    var helmcodeCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .helmcode, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .helmcode) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .helmcode, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureHelmcodeCookieLoaded() {}

    func helmcodeSettingsSnapshot(tokenOverride: TokenAccountOverride?)
        -> ProviderSettingsSnapshot.HelmcodeProviderSettings
    {
        self.resolvedCookieSettings(
            provider: .helmcode,
            configuredSource: self.helmcodeCookieSource,
            configuredHeader: self.helmcodeCookieHeader,
            tokenOverride: tokenOverride)
    }
}
