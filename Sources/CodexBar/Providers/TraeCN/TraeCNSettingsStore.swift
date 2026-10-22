import CodexBarCore
import Foundation

extension SettingsStore {
    var traeCNCookieHeader: String {
        get { self[providerConfig: .traecn, field: .cookieHeader] }
        set { self[providerConfig: .traecn, field: .cookieHeader] = newValue }
    }

    var traeCNCookieSource: ProviderCookieSource {
        // Trae CN has no browser import, so a fresh configuration starts in Manual.
        get { self.resolvedCookieSource(provider: .traecn, fallback: .manual) }
        set { self.setCookieSource(newValue, provider: .traecn) }
    }

    func traeCNSettingsSnapshot(tokenOverride: TokenAccountOverride?)
        -> ProviderSettingsSnapshot.TraeCNProviderSettings
    {
        let cookieSettings: ProviderSettingsSnapshot.CookieProviderSettings = self.resolvedCookieSettings(
            provider: .traecn,
            configuredSource: self.traeCNCookieSource,
            configuredHeader: self[providerConfig: .traecn, field: .cookieHeader],
            tokenOverride: tokenOverride)
        return ProviderSettingsSnapshot.TraeCNProviderSettings(
            cookieSource: cookieSettings.cookieSource,
            manualCookieHeader: cookieSettings.manualCookieHeader)
    }
}
