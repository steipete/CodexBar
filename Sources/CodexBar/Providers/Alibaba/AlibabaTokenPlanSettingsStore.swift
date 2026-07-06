import CodexBarCore
import Foundation

extension SettingsStore {
    var alibabaTokenPlanCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .alibabatokenplan)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .alibabatokenplan) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .alibabatokenplan, field: "cookieHeader", value: newValue)
        }
    }

    var alibabaTokenPlanCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .alibabatokenplan, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .alibabatokenplan) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .alibabatokenplan, field: "cookieSource", value: newValue.rawValue)
        }
    }

    var alibabaTokenPlanAPIRegion: AlibabaTokenPlanAPIRegion {
        get {
            let raw = self.configSnapshot.providerConfig(for: .alibabatokenplan)?.sanitizedRegion
            return AlibabaTokenPlanAPIRegion(rawValue: raw ?? "") ?? .chinaMainland
        }
        set {
            self.updateProviderConfig(provider: .alibabatokenplan) { entry in
                entry.region = newValue.rawValue
            }
        }
    }

    func alibabaTokenPlanSettingsSnapshot() -> ProviderSettingsSnapshot.AlibabaTokenPlanProviderSettings {
        ProviderSettingsSnapshot.AlibabaTokenPlanProviderSettings(
            cookieSource: self.alibabaTokenPlanCookieSource,
            manualCookieHeader: self.alibabaTokenPlanCookieHeader,
            apiRegion: self.alibabaTokenPlanAPIRegion)
    }
}
