import CodexBarCore
import Foundation

extension SettingsStore {
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

    func ensureOllamaCookieLoaded() {}
}

extension SettingsStore {
    func ollamaSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .OllamaProviderSettings {
        ProviderSettingsSnapshot.OllamaProviderSettings(
            cookieSource: self.ollamaSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.ollamaSnapshotCookieHeader(tokenOverride: tokenOverride))
    }

    private func ollamaSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.ollamaCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .ollama),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .ollama,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func ollamaSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.ollamaCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .ollama),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .ollama).isEmpty { return fallback }
        return .manual
    }
}
