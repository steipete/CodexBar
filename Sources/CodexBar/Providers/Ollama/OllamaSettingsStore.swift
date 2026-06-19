import CodexBarCore
import Foundation

extension SettingsStore {
    var ollamaUsageDataSource: ProviderSourceMode {
        get {
            let source = self.configSnapshot.providerConfig(for: .ollama)?.source
            return source ?? .auto
        }
        set {
            self.updateProviderConfig(provider: .ollama) { entry in
                entry.source = newValue == .auto ? nil : newValue
            }
            self.logProviderModeChange(provider: .ollama, field: "source", value: newValue.rawValue)
        }
    }

    var ollamaAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .ollama)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .ollama) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .ollama, field: "apiKey", value: newValue)
        }
    }

    var ollamaCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .ollama)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .ollama) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .ollama, field: "cookieHeader", value: newValue)
        }
    }

    var ollamaCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .ollama, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .ollama) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .ollama, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureOllamaAPITokenLoaded() {}

    func ensureOllamaCookieLoaded() {}
}

extension SettingsStore {
    func ollamaSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .OllamaProviderSettings {
        self.resolvedCookieSettings(
            provider: .ollama,
            configuredSource: self.ollamaCookieSource,
            configuredHeader: self.ollamaCookieHeader,
            tokenOverride: tokenOverride)
    }
}
