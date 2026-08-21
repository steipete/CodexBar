import CodexBarCore
import Foundation

/// Provider-specific by design: The Alibaba folder co-locates settings for the distinct Token Plan variant.
extension SettingsStore {
    var alibabaTokenPlanUsageDataSource: ProviderSourceMode {
        // An unset source predates the Bailian CLI source and stays Web-only:
        // browser-cookie fetches only, no CLI fallback. Explicitly selecting
        // Auto in settings persists `.auto` and opts into Web -> CLI fallback.
        get { self.configSnapshot.providerConfig(for: .alibabatokenplan)?.source ?? .web }
        set {
            self.updateProviderConfig(provider: .alibabatokenplan) { entry in
                entry.source = newValue
            }
            self.logProviderModeChange(
                provider: .alibabatokenplan,
                field: "source",
                value: newValue.rawValue)
        }
    }

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
