import CodexBarCore
import Foundation

extension SettingsStore {
    var minimaxAPIRegion: MiniMaxAPIRegion {
        get {
            let raw = self.configSnapshot.providerConfig(for: .minimax)?.region
            return MiniMaxAPIRegion(rawValue: raw ?? "") ?? .global
        }
        set {
            self.updateProviderConfig(provider: .minimax) { entry in
                entry.region = newValue.rawValue
            }
        }
    }

    var minimaxCookieHeader: String {
        get { self[providerConfig: .minimax, field: .cookieHeader] }
        set { self[providerConfig: .minimax, field: .cookieHeader] = newValue }
    }

    var minimaxAPIToken: String {
        get { self[providerConfig: .minimax, field: .apiKey] }
        set { self[providerConfig: .minimax, field: .apiKey] = newValue }
    }

    var minimaxCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .minimax, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .minimax) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .minimax, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func minimaxAuthMode(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> MiniMaxAuthMode
    {
        let apiToken = MiniMaxAPISettingsReader.apiToken(environment: environment) ?? self.minimaxAPIToken
        let cookieHeader = MiniMaxSettingsReader.cookieHeader(environment: environment) ?? self.minimaxCookieHeader
        return MiniMaxAuthMode.resolve(apiToken: apiToken, cookieHeader: cookieHeader)
    }
}

extension SettingsStore {
    func minimaxSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .MiniMaxProviderSettings {
        let cookieSettings: ProviderSettingsSnapshot.CookieProviderSettings = self.resolvedCookieSettings(
            provider: .minimax,
            configuredSource: self.minimaxCookieSource,
            configuredHeader: self.minimaxCookieHeader,
            tokenOverride: tokenOverride)
        return ProviderSettingsSnapshot.MiniMaxProviderSettings(
            cookieSource: cookieSettings.cookieSource,
            manualCookieHeader: cookieSettings.manualCookieHeader,
            apiRegion: self.minimaxAPIRegion)
    }
}
