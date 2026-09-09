import CodexBarCore
import Foundation

extension SettingsStore {
    var huggingFaceUsageDataSource: ProviderSourceMode {
        get {
            let source = self.configSnapshot.providerConfig(for: .huggingface)?.source
            return source ?? .auto
        }
        set {
            self.updateProviderConfig(provider: .huggingface) { entry in
                entry.source = newValue == .auto ? nil : newValue
            }
            self.logProviderModeChange(provider: .huggingface, field: "source", value: newValue.rawValue)
        }
    }

    var huggingFaceManualCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .huggingface)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .huggingface) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .huggingface, field: "cookieHeader", value: newValue)
        }
    }

    var huggingFaceCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .huggingface, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .huggingface) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .huggingface, field: "cookieSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    func huggingFaceSettingsSnapshot(tokenOverride: TokenAccountOverride?)
        -> ProviderSettingsSnapshot.HuggingFaceProviderSettings
    {
        self.resolvedCookieSettings(
            provider: .huggingface,
            configuredSource: self.huggingFaceCookieSource,
            configuredHeader: self.huggingFaceManualCookieHeader,
            tokenOverride: tokenOverride)
    }
}
