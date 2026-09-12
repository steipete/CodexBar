import CodexBarCore
import Foundation

/// Provider-specific by design: The Alibaba folder co-locates settings for the distinct Token Plan variant.
extension SettingsStore {
    var alibabaTokenPlanUsageDataSource: ProviderSourceMode {
        get { self.configSnapshot.providerConfig(for: .alibabatokenplan)?.source ?? .auto }
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
        get { self[providerConfig: .alibabatokenplan, field: .cookieHeader] }
        set { self[providerConfig: .alibabatokenplan, field: .cookieHeader] = newValue }
    }

    var alibabaTokenPlanCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .alibabatokenplan, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .alibabatokenplan) }
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
