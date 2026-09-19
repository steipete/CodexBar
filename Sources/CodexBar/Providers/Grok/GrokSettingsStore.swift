import CodexBarCore
import Foundation

extension SettingsStore {
    var grokUsageDataSource: ProviderSourceMode {
        get { self.configSnapshot.providerConfig(for: .grok)?.source ?? .auto }
        set {
            self.updateProviderConfig(provider: .grok) { entry in
                entry.source = newValue == .auto ? nil : newValue
            }
            self.logProviderModeChange(provider: .grok, field: "source", value: newValue.rawValue)
        }
    }

    var grokCookieHeader: String {
        get { self[providerConfig: .grok, field: .cookieHeader] }
        set { self[providerConfig: .grok, field: .cookieHeader] = newValue }
    }

    var grokCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .grok, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .grok) }
    }
}

extension SettingsStore {
    func grokSettingsSnapshot(tokenOverride: TokenAccountOverride?)
        -> ProviderSettingsSnapshot
        .GrokProviderSettings
    {
        let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .grok,
            settings: self,
            override: tokenOverride)
        let resolved = GrokCredentialRouting.cookieSettings(
            configuredSource: self.grokCookieSource,
            configuredHeader: self.grokCookieHeader,
            selectedAccountToken: account?.token)
        return GrokProviderSettings(
            cookieSource: resolved.cookieSource,
            manualCookieHeader: resolved.manualCookieHeader)
    }
}
