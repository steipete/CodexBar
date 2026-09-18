import CodexBarCore
import Foundation

extension SettingsStore {
    var helmcodeDeploymentSelection: HelmcodeDeploymentSelection {
        get {
            let raw = self.configSnapshot.providerConfig(for: .helmcode)?.region
            return HelmcodeDeploymentSelection(rawValue: raw ?? "") ?? .auto
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

    /// The detected tenant while Automatic is selected, for the picker subtitle and the dashboard action.
    /// Reads the memoized display cache: this is called during SwiftUI body evaluations.
    var helmcodeDetectedDeployment: HelmcodeDeployment? {
        HelmcodeDeploymentResolver.detectTenantFromCacheForDisplay()
    }

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
            deploymentSelection: self.helmcodeDeploymentSelection)
    }
}
