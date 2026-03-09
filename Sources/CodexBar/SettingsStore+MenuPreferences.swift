import CodexBarCore
import Foundation

extension SettingsStore {
    func menuBarMetricPreference(for provider: UsageProvider) -> MenuBarMetricPreference {
        if provider == .zai { return .primary }
        if provider == .openrouter {
            let raw = self.menuBarMetricPreferencesRaw[provider.rawValue] ?? ""
            let preference = MenuBarMetricPreference(rawValue: raw) ?? .automatic
            switch preference {
            case .automatic, .primary:
                return preference
            case .secondary, .average:
                return .automatic
            }
        }
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
        if provider == .openrouter {
            switch preference {
            case .automatic, .primary:
                self.menuBarMetricPreferencesRaw[provider.rawValue] = preference.rawValue
            case .secondary, .average:
                self.menuBarMetricPreferencesRaw[provider.rawValue] = MenuBarMetricPreference.automatic.rawValue
            }
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
