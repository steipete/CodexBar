import CodexBarCore
import Foundation

extension SettingsStore {
    var museAPIToken: String {
        get {
            guard let config = self.configSnapshot.providerConfig(for: .muse) else { return "" }
            return config.sanitizedAPIKey ?? ""
        }
        set {
            self.updateProviderConfig(provider: .muse) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .muse, field: "apiKey", value: newValue)
        }
    }

    var museBaseURL: String {
        get {
            guard let config = self.configSnapshot.providerConfig(for: .muse) else { return "" }
            return config.sanitizedBaseURL ?? ""
        }
        set {
            self.updateProviderConfig(provider: .muse) { entry in
                entry.baseURL = self.normalizedConfigValue(newValue)
            }
        }
    }

    var museCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .muse)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .muse) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .muse, field: "cookieHeader", value: newValue)
        }
    }

    var museCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .muse, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .muse) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .muse, field: "cookieSource", value: newValue.rawValue)
        }
    }

    var museBrowserSource: MuseBrowserSource {
        get { self.configSnapshot.providerConfig(for: .muse)?.museBrowserSource ?? .auto }
        set {
            self.updateProviderConfig(provider: .muse) { entry in
                entry.museBrowserSource = newValue == .auto ? nil : newValue
            }
            self.logProviderModeChange(provider: .muse, field: "browserSource", value: newValue.rawValue)
        }
    }

    func ensureMuseAPITokenLoaded() {}

    var hasMuseAPIToken: Bool {
        guard let config = self.configSnapshot.providerConfig(for: .muse) else { return false }
        return config.sanitizedAPIKey != nil
    }

    var configuredMuseBaseURL: String? {
        guard let raw = self.configSnapshot.providerConfig(for: .muse)?.baseURL?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }
        return raw
    }
}

extension SettingsStore {
    func museSettingsSnapshot() -> ProviderSettingsSnapshot.MuseProviderSettings {
        let cookie: MuseProviderSettings = self.resolvedCookieSettings(
            provider: .muse,
            configuredSource: self.museCookieSource,
            configuredHeader: self.museCookieHeader,
            tokenOverride: nil)
        return ProviderSettingsSnapshot.MuseProviderSettings(
            baseURL: self.configuredMuseBaseURL,
            browserSource: self.museBrowserSource,
            cookieSource: cookie.cookieSource,
            manualCookieHeader: cookie.manualCookieHeader)
    }
}
