import CodexBarCore
import Foundation

extension SettingsStore {
    var antigravityAdditionalProfileHomes: [String] {
        get { self.configSnapshot.providerConfig(for: .antigravity)?.antigravityAdditionalProfileHomes ?? [] }
        set {
            self.updateProviderConfig(provider: .antigravity) { $0.antigravityAdditionalProfileHomes = newValue }
        }
    }

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

    var antigravityPrimaryPoolPreference: AntigravityPrimaryPoolPreference {
        get {
            self.configSnapshot.providerConfig(for: .antigravity)?.resolvedAntigravityPrimaryPoolPreference ?? .auto
        }
        set {
            self.updateProviderConfig(provider: .antigravity) { entry in
                entry.antigravityPrimaryPoolPreference = newValue == .auto ? nil : newValue.rawValue
            }
            self.logProviderModeChange(
                provider: .antigravity,
                field: "primaryPoolPreference",
                value: newValue.rawValue)
        }
    }

    var antigravityShowCredits: Bool {
        get {
            self.configSnapshot.providerConfig(for: .antigravity)?.antigravityShowCredits ?? true
        }
        set {
            self.updateProviderConfig(provider: .antigravity) { entry in
                entry.antigravityShowCredits = newValue
            }
            self.logProviderModeChange(
                provider: .antigravity,
                field: "showCredits",
                value: "\(newValue)")
        }
    }

    var antigravityScanDesktopEnabled: Bool {
        get {
            self.configSnapshot.providerConfig(for: .antigravity)?.antigravityScanDesktopEnabled ?? true
        }
        set {
            self.updateProviderConfig(provider: .antigravity) { entry in
                entry.antigravityScanDesktopEnabled = newValue
            }
            self.logProviderModeChange(
                provider: .antigravity,
                field: "scanDesktopEnabled",
                value: "\(newValue)")
        }
    }

    var antigravityScanCLIEnabled: Bool {
        get {
            self.configSnapshot.providerConfig(for: .antigravity)?.antigravityScanCLIEnabled ?? true
        }
        set {
            self.updateProviderConfig(provider: .antigravity) { entry in
                entry.antigravityScanCLIEnabled = newValue
            }
            self.logProviderModeChange(
                provider: .antigravity,
                field: "scanCLIEnabled",
                value: "\(newValue)")
        }
    }

    var antigravityTokscaleFallbackEnabled: Bool {
        get {
            self.configSnapshot.providerConfig(for: .antigravity)?.antigravityTokscaleFallbackEnabled ?? true
        }
        set {
            self.updateProviderConfig(provider: .antigravity) { entry in
                entry.antigravityTokscaleFallbackEnabled = newValue
            }
            self.logProviderModeChange(
                provider: .antigravity,
                field: "tokscaleFallbackEnabled",
                value: "\(newValue)")
        }
    }

    var antigravityProjectGrouping: AntigravityProjectGrouping {
        get {
            self.configSnapshot.providerConfig(for: .antigravity)?.resolvedAntigravityProjectGrouping ?? .workspace
        }
        set {
            self.updateProviderConfig(provider: .antigravity) { entry in
                entry.antigravityProjectGrouping = newValue == .workspace ? nil : newValue.rawValue
            }
            self.logProviderModeChange(
                provider: .antigravity,
                field: "projectGrouping",
                value: newValue.rawValue)
        }
    }

    var antigravityLocalScanOptions: AntigravityLocalScanOptions {
        AntigravityLocalScanOptions(
            includeDesktopDatabases: self.antigravityScanDesktopEnabled,
            includeCLIDatabases: self.antigravityScanCLIEnabled,
            includeTokscaleFallback: self.antigravityTokscaleFallbackEnabled,
            projectGrouping: self.antigravityProjectGrouping)
    }

    func antigravitySettingsSnapshot() -> AntigravityProviderSettings {
        AntigravityProviderSettings(
            primaryPoolPreference: self.antigravityPrimaryPoolPreference,
            showCredits: self.antigravityShowCredits)
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
