import CodexBarCore
import Foundation

extension SettingsStore {
    var codebuddyManualCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .codebuddy)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .codebuddy) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .codebuddy, field: "cookieHeader", value: newValue)
        }
    }

    var codebuddyCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .codebuddy, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .codebuddy) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .codebuddy, field: "cookieSource", value: newValue.rawValue)
        }
    }

    /// Default enterprise ID for most CodeBuddy users
    private static let defaultEnterpriseID = "etahzsqej0n4"

    var codebuddyEnterpriseID: String {
        get {
            let stored = self.configSnapshot.providerConfig(for: .codebuddy)?.enterpriseID
            // Use default if not explicitly set
            return stored ?? Self.defaultEnterpriseID
        }
        set {
            self.updateProviderConfig(provider: .codebuddy) { entry in
                // Only store if different from default
                let normalized = self.normalizedConfigValue(newValue)
                entry.enterpriseID = (normalized == Self.defaultEnterpriseID) ? nil : normalized
            }
            self.logSecretUpdate(provider: .codebuddy, field: "enterpriseID", value: newValue)
        }
    }

    func ensureCodeBuddySessionLoaded() {}
}

extension SettingsStore {
    func codebuddySettingsSnapshot(
        tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.CodeBuddyProviderSettings
    {
        _ = tokenOverride
        self.ensureCodeBuddySessionLoaded()
        return ProviderSettingsSnapshot.CodeBuddyProviderSettings(
            cookieSource: self.codebuddyCookieSource,
            manualCookieHeader: self.codebuddyManualCookieHeader,
            enterpriseID: self.codebuddyEnterpriseID.isEmpty ? nil : self.codebuddyEnterpriseID)
    }
}
