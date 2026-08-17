import CodexBarCore
import Foundation

extension SettingsStore {
    var xaiUsageDataSource: ProviderSourceMode {
        get { self.configSnapshot.providerConfig(for: .xai)?.source ?? .auto }
        set {
            self.updateProviderConfig(provider: .xai) { entry in
                entry.source = newValue == .auto ? nil : newValue
            }
            self.logProviderModeChange(provider: .xai, field: "source", value: newValue.rawValue)
        }
    }

    var xaiCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .xai)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .xai) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .xai, field: "cookieHeader", value: newValue)
        }
    }

    var xaiCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .xai, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .xai) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(
                provider: .xai, field: "cookieSource", value: newValue.rawValue)
        }
    }

    var xaiAllowGrokCLICredentials: Bool {
        get {
            XAISettingsReader.allowGrokCLICredentials(
                pluginSettings: self.configSnapshot.providerConfig(for: .xai)?.pluginSettings)
        }
        set {
            self.updateProviderConfig(provider: .xai) { entry in
                var values = entry.pluginSettings ?? [:]
                if newValue {
                    values[XAISettingsReader.allowGrokCLICredentialsSettingsKey] = "true"
                } else {
                    values.removeValue(forKey: XAISettingsReader.allowGrokCLICredentialsSettingsKey)
                }
                entry.pluginSettings = values.isEmpty ? nil : values
            }
            self.logProviderModeChange(
                provider: .xai,
                field: "allowGrokCLICredentials",
                value: newValue ? "true" : "false")
        }
    }

    func ensureXAICookieLoaded() {}

    func xaiSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> XAIProviderSettings {
        let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .xai,
            settings: self,
            override: tokenOverride)
        return XAIProviderSettings.resolved(
            pickerSource: self.xaiUsageDataSource,
            tokenAccountToken: account?.token,
            configuredCookieSource: self.xaiCookieSource,
            configuredCookieHeader: account == nil ? self.xaiCookieHeader : nil,
            allowGrokCLICredentials: self.xaiAllowGrokCLICredentials)
    }
}
