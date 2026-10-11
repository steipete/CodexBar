import CodexBarCore
import Foundation

extension SettingsStore {
    var grokBotUsageEnabled: Bool {
        get { self.configSnapshot.providerConfig(for: .grok)?.grokBotUsageEnabled ?? false }
        set {
            self.updateProviderConfig(provider: .grok) { $0.grokBotUsageEnabled = newValue }
        }
    }

    /// An opt-out hides cached Bot readings immediately, including saved-account snapshots.
    func grokBotUsageFilteredSnapshot(_ snapshot: UsageSnapshot?, provider: ProviderInstanceID) -> UsageSnapshot? {
        guard provider == .grok, !self.grokBotUsageEnabled, let snapshot else { return snapshot }
        return GrokBotUsageEnrichment.removingBotUsage(from: snapshot)
    }

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
        // Provider-specific by design: Bot usage keeps the linked Cursor account's source policy.
        let cursorCookies: ProviderSettingsSnapshot.CookieProviderSettings = self.resolvedCookieSettings(
            provider: .cursor, tokenOverride: nil)
        let configuredCursorSource = self.configSnapshot.providerConfig(for: .cursor)?.cookieSource ?? .auto
        let botCookieSource: ProviderCookieSource? = self.debugDisableKeychainAccess
            && configuredCursorSource == .auto
            && CookieHeaderNormalizer.normalize(cursorCookies.manualCookieHeader) == nil ? .auto : nil
        return GrokProviderSettings(
            cookieSource: resolved.cookieSource,
            manualCookieHeader: resolved.manualCookieHeader,
            grokBotUsageEnabled: self.grokBotUsageEnabled,
            grokBotSourceMode: self.configSnapshot.providerConfig(for: .cursor)?.source ?? .auto,
            grokBotCursorCookieSource: botCookieSource)
    }
}
