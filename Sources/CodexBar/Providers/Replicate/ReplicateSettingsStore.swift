import CodexBarCore
import Foundation

extension SettingsStore {
    var replicateCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .replicate)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .replicate) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .replicate, field: "cookieHeader", value: newValue)
        }
    }

    var replicateCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .replicate, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .replicate) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .replicate, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureReplicateCookieLoaded() {}
}

extension SettingsStore {
    func replicateSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
        .ReplicateProviderSettings
    {
        self.resolvedCookieSettings(
            provider: .replicate,
            configuredSource: self.replicateCookieSource,
            configuredHeader: self.replicateCookieHeader,
            tokenOverride: tokenOverride)
    }
}
