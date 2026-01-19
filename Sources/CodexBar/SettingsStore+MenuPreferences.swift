import CodexBarCore
import Foundation

extension SettingsStore {
    func menuBarMetricPreference(for provider: UsageProvider) -> MenuBarMetricPreference {
        if provider == .zai { return .primary }
        let raw = self.menuBarMetricPreferencesRaw[provider.rawValue] ?? ""
        let preference = MenuBarMetricPreference(rawValue: raw) ?? .automatic
        if preference == .average, !self.menuBarMetricSupportsAverage(for: provider) {
            return .automatic
        }
        return preference
    }

    func setMenuBarMetricPreference(_ preference: MenuBarMetricPreference, for provider: UsageProvider) {
        if provider == .zai {
            self.menuBarMetricPreferencesRaw[provider.rawValue] = MenuBarMetricPreference.primary.rawValue
            return
        }
        self.menuBarMetricPreferencesRaw[provider.rawValue] = preference.rawValue
    }

    func menuBarMetricSupportsAverage(for provider: UsageProvider) -> Bool {
        provider == .gemini
    }

    func isCostUsageEffectivelyEnabled(for provider: UsageProvider) -> Bool {
        self.costUsageEnabled
            && ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost
    }

    var resetTimeDisplayStyle: ResetTimeDisplayStyle {
        self.resetTimesShowAbsolute ? .absolute : .countdown
    }
}
