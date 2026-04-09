import CodexBarCore
import Foundation

extension SettingsStore {
    var rovodevCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .rovodev)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .rovodev) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .rovodev, field: "cookieHeader", value: newValue)
        }
    }

    var rovodevCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .rovodev, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .rovodev) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .rovodev, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureRovoDevCookieLoaded() {}
}

extension SettingsStore {
    func rovodevSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .RovoDevProviderSettings {
        ProviderSettingsSnapshot.RovoDevProviderSettings(
            cookieSource: self.rovodevSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.rovodevSnapshotCookieHeader(tokenOverride: tokenOverride))
    }

    private func rovodevSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String? {
        let fallback = self.rovodevCookieHeader.isEmpty ? nil : self.rovodevCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .rovodev),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .rovodev,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func rovodevSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.rovodevCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .rovodev),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .rovodev).isEmpty { return fallback }
        return .manual
    }
}
