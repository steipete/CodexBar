import CodexBarCore
import Foundation

extension SettingsStore {
    var helmcodeDeployment: HelmcodeDeployment {
        get {
            let raw = self.configSnapshot.providerConfig(for: .helmcode)?.region
            return HelmcodeDeployment(rawValue: raw ?? "") ?? .helmcode
        }
        set {
            self.updateProviderConfig(provider: .helmcode) { entry in
                entry.region = newValue.rawValue
            }
            self.logProviderModeChange(provider: .helmcode, field: "deployment", value: newValue.rawValue)
        }
    }

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
        let resolved: ProviderSettingsSnapshot.HelmcodeProviderSettings = self.resolvedCookieSettings(
            provider: .helmcode,
            configuredSource: self.helmcodeCookieSource,
            configuredHeader: self.helmcodeCookieHeader,
            tokenOverride: tokenOverride)
        return HelmcodeProviderSettings(
            cookieSource: resolved.cookieSource,
            manualCookieHeader: resolved.manualCookieHeader,
            deployment: self.helmcodeDeployment)
    }
}
