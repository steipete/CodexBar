import CodexBarCore
import Foundation

extension SettingsStore {
    var cursorCookieHeader: String {
        get { self[providerConfig: .cursor, field: .cookieHeader] }
        set { self[providerConfig: .cursor, field: .cookieHeader] = newValue }
    }

    var cursorCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .cursor, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .cursor) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .cursor, field: "cookieSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    func cursorSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .CursorProviderSettings {
        self.resolvedCookieSettings(
            provider: .cursor,
            configuredSource: self.cursorCookieSource,
            configuredHeader: self.cursorCookieHeader,
            tokenOverride: tokenOverride)
    }
}
