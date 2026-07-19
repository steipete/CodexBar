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
        let cookieSettings: ProviderSettingsSnapshot.CookieProviderSettings = self.resolvedCookieSettings(
            provider: .windsurf,
            configuredSource: self.windsurfCookieSource,
            configuredHeader: self.windsurfCookieHeader,
            tokenOverride: tokenOverride)
        return ProviderSettingsSnapshot.WindsurfProviderSettings(
            usageDataSource: self.windsurfUsageDataSource,
            cookieSource: cookieSettings.cookieSource,
            manualCookieHeader: cookieSettings.manualCookieHeader)
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
}
