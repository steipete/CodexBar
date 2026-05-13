import CodexBarCore
import Foundation

extension SettingsStore {
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
        let email = credentials.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (email?.isEmpty == false) ? email! : "Google Account"
        let data = self.tokenAccountsData(for: .antigravity)
        if let data,
           let index = data.accounts.firstIndex(where: { account in
               account.externalIdentifier == email || account.label == label
           })
        {
            let account = data.accounts[index]
            self.updateTokenAccount(
                provider: .antigravity,
                accountID: account.id,
                label: label,
                token: token,
                externalIdentifier: .some(email),
                organizationID: .some(nil))
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
