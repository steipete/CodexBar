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
        get { self.configSnapshot.providerConfig(for: .minimax)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .minimax) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .minimax, field: "cookieHeader", value: newValue)
        }
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

    var minimaxAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .minimax)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .minimax) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            let hasToken = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasToken,
               let metadata = ProviderDescriptorRegistry.metadata[.minimax],
               !self.isProviderEnabled(provider: .minimax, metadata: metadata)
            {
                self.setProviderEnabled(provider: .minimax, metadata: metadata, enabled: true)
            }
            self.logSecretUpdate(provider: .minimax, field: "apiKey", value: newValue)
        }
    }
}

extension SettingsStore {
    func minimaxSettingsSnapshot() -> ProviderSettingsSnapshot.MiniMaxProviderSettings {
        ProviderSettingsSnapshot.MiniMaxProviderSettings(
            cookieSource: self.minimaxCookieSource,
            manualCookieHeader: self.minimaxCookieHeader,
            apiRegion: self.minimaxAPIRegion)
    }
}

extension SettingsStore {
    func ensureMiniMaxCookieLoaded() {
        // Cookie loading handled by MiniMaxCookieImporter
    }
}

extension SettingsStore {
    func ensureMiniMaxAPITokenLoaded() {
        // Token loading handled by MiniMaxAPITokenStore
    }
}

extension SettingsStore {
    func minimaxAuthMode() -> MiniMaxAuthMode {
        MiniMaxAuthMode.resolve(
            apiToken: self.minimaxAPIToken,
            cookieHeader: self.minimaxCookieHeader)
    }
}
