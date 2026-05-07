import CodexBarCore
import Foundation

extension SettingsStore {
    private static let alibabaAutoEnableAppliedKey = "alibabaCodingPlanAutoEnableApplied"

    var alibabaCodingPlanAPIRegion: AlibabaCodingPlanAPIRegion {
        get {
            let raw = self.configSnapshot.providerConfig(for: .alibaba)?.region
            return AlibabaCodingPlanAPIRegion(rawValue: raw ?? "") ?? .international
        }
        set {
            self.updateProviderConfig(provider: .alibaba) { entry in
                entry.region = newValue.rawValue
            }
        }
    }

    var alibabaCodingPlanCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .alibaba)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .alibaba) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .alibaba, field: "cookieHeader", value: newValue)
        }
    }

    var alibabaCodingPlanCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .alibaba, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .alibaba) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .alibaba, field: "cookieSource", value: newValue.rawValue)
        }
    }

    var alibabaCodingPlanAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .alibaba)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .alibaba) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            let hasToken = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasToken,
               let metadata = ProviderDescriptorRegistry.metadata[.alibaba],
               !self.isProviderEnabled(provider: .alibaba, metadata: metadata)
            {
                self.setProviderEnabled(provider: .alibaba, metadata: metadata, enabled: true)
            }
            self.logSecretUpdate(provider: .alibaba, field: "apiKey", value: newValue)
        }
    }

    func ensureAlibabaCodingPlanAPITokenLoaded() {}

    func ensureAlibabaProviderAutoEnabledIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        guard self.userDefaults.bool(forKey: Self.alibabaAutoEnableAppliedKey) == false else { return }

        let hasConfigToken = self.configSnapshot.providerConfig(for: .alibaba)?.sanitizedAPIKey != nil
        let shouldUseEnvironmentToken = !Self.isRunningTests || self.userDefaults === UserDefaults.standard
        let hasEnvironmentToken = shouldUseEnvironmentToken &&
            AlibabaCodingPlanSettingsReader.apiToken(environment: environment) != nil
        guard hasConfigToken || hasEnvironmentToken else { return }

        if let metadata = ProviderDescriptorRegistry.metadata[.alibaba],
           !self.isProviderEnabled(provider: .alibaba, metadata: metadata)
        {
            self.setProviderEnabled(provider: .alibaba, metadata: metadata, enabled: true)
        }

        self.userDefaults.set(true, forKey: Self.alibabaAutoEnableAppliedKey)
    }
}

extension SettingsStore {
    func alibabaCodingPlanSettingsSnapshot() -> ProviderSettingsSnapshot.AlibabaCodingPlanProviderSettings {
        ProviderSettingsSnapshot.AlibabaCodingPlanProviderSettings(
            cookieSource: self.alibabaCodingPlanCookieSource,
            manualCookieHeader: self.alibabaCodingPlanCookieHeader,
            apiRegion: self.alibabaCodingPlanAPIRegion)
    }
}
