import CodexBarCore
import Foundation

extension SettingsStore {
    var antigravityPrioritizeExhaustedQuotas: Bool {
        get {
            self.configSnapshot.providerConfig(for: .antigravity)?.antigravityPrioritizeExhaustedQuotas ?? false
        }
        set {
            self.updateProviderConfig(provider: .antigravity) { entry in
                entry.antigravityPrioritizeExhaustedQuotas = newValue
            }
            self.logProviderModeChange(
                provider: .antigravity,
                field: "prioritizeExhaustedQuotas",
                value: "\(newValue)")
        }
    }

    var antigravityUsageDataSource: AntigravityUsageDataSource {
        get {
            let source = self.configSnapshot.providerConfig(for: .antigravity)?.source
            return Self.antigravityUsageDataSource(from: source)
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .oauth: .oauth
            case .cli: .cli
            }
            self.updateProviderConfig(provider: .antigravity) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .antigravity, field: "usageSource", value: newValue.rawValue)
        }
    }

    func upsertAntigravityOAuthAccount(_ credentials: AntigravityOAuthCredentials) {
        guard let token = try? AntigravityOAuthCredentialsStore.tokenAccountValue(for: credentials) else { return }
        let trimmedEmail = credentials.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (trimmedEmail?.isEmpty == false) ? trimmedEmail : nil
        let data = self.tokenAccountsData(for: .antigravity)
        let label = email ?? "Google Account \((data?.accounts.count ?? 0) + 1)"
        if let email,
           let data,
           let index = data.accounts.firstIndex(where: { account in
               account.externalIdentifier == email
           })
        {
            let account = data.accounts[index]
            self.updateTokenAccount(
                provider: .antigravity,
                accountID: account.id,
                label: label,
                token: token,
                externalIdentifier: .some(email))
            self.setActiveTokenAccountIndex(index, for: .antigravity)
        } else {
            self.addTokenAccount(
                provider: .antigravity,
                label: label,
                token: token,
                externalIdentifier: email)
        }
    }
}

extension SettingsStore {
    private static func antigravityUsageDataSource(from source: ProviderSourceMode?) -> AntigravityUsageDataSource {
        guard let source else { return .auto }
        switch source {
        case .auto, .web, .api:
            return .auto
        case .oauth:
            return .oauth
        case .cli:
            return .cli
        }
    }
}
