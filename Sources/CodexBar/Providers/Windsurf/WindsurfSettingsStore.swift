import CodexBarCore
import Foundation

extension SettingsStore {
    var windsurfUsageDataSource: WindsurfUsageDataSource {
        get {
            let source = self.configSnapshot.providerConfig(for: .windsurf)?.source
            return Self.windsurfUsageDataSource(from: source)
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .web: .web
            case .cli: .cli
            }
            self.updateProviderConfig(provider: .windsurf) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .windsurf, field: "usageSource", value: newValue.rawValue)
        }
    }

    var windsurfCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .windsurf, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .windsurf) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .windsurf, field: "cookieSource", value: newValue.rawValue)
        }
    }

    var windsurfCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .windsurf)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .windsurf) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .windsurf, field: "cookieHeader", value: newValue)
        }
    }
}

extension SettingsStore {
    func windsurfSettingsSnapshot(
        tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.WindsurfProviderSettings
    {
        ProviderSettingsSnapshot.WindsurfProviderSettings(
            usageDataSource: self.windsurfUsageDataSource,
            cookieSource: self.windsurfSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.windsurfSnapshotCookieHeader(tokenOverride: tokenOverride))
    }

    private static func windsurfUsageDataSource(from source: ProviderSourceMode?) -> WindsurfUsageDataSource {
        guard let source else { return .auto }
        switch source {
        case .auto, .oauth, .api:
            return .auto
        case .web:
            return .web
        case .cli:
            return .cli
        }
    }

    private func windsurfSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.windsurfCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .windsurf),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .windsurf,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func windsurfSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.windsurfCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .windsurf),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .windsurf).isEmpty { return fallback }
        return .manual
    }
}
