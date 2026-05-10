import CodexBarCore
import Foundation

extension SettingsStore {
    /// Username for StepFun login — stored in the apiKey config field.
    var stepfunUsername: String {
        get { self.configSnapshot.providerConfig(for: .stepfun)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .stepfun) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logProviderModeChange(
                provider: .stepfun,
                field: "username",
                value: newValue.isEmpty ? "(cleared)" : "(updated)")
        }
    }

    /// Password for StepFun login — stored in the cookieHeader config field (secure storage).
    var stepfunPassword: String {
        get { self.configSnapshot.providerConfig(for: .stepfun)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .stepfun) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .stepfun, field: "password", value: newValue)
        }
    }

    /// Manual Oasis-Token — stored in the region config field (repurposed for token).
    var stepfunToken: String {
        get { self.configSnapshot.providerConfig(for: .stepfun)?.region ?? "" }
        set {
            self.updateProviderConfig(provider: .stepfun) { entry in
                entry.region = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .stepfun, field: "token", value: newValue)
        }
    }

    var stepfunCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .stepfun, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .stepfun) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .stepfun, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func stepfunSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
        .StepFunProviderSettings
    {
        ProviderSettingsSnapshot.StepFunProviderSettings(
            cookieSource: self.stepfunSnapshotCookieSource(tokenOverride: tokenOverride),
            manualToken: self.stepfunSnapshotToken(tokenOverride: tokenOverride),
            username: self.stepfunUsername,
            password: self.stepfunPassword)
    }

    private func stepfunSnapshotToken(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.stepfunToken
        guard let support = TokenAccountSupportCatalog.support(for: .stepfun),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .stepfun,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func stepfunSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.stepfunCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .stepfun),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .stepfun).isEmpty { return fallback }
        return .manual
    }
}
