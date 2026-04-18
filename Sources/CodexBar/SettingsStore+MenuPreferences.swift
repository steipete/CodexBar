import CodexBarCore
import Foundation

extension SettingsStore {
    func menuBarMetricPreference(for provider: UsageProvider) -> MenuBarMetricPreference {
        if provider == .openrouter {
            let raw = self.menuBarMetricPreferencesRaw[provider.rawValue] ?? ""
            let preference = MenuBarMetricPreference(rawValue: raw) ?? .automatic
            switch preference {
            case .automatic, .primary:
                return preference
            case .secondary, .average, .tertiary:
                return .automatic
            }
        }
        let raw = self.menuBarMetricPreferencesRaw[provider.rawValue] ?? ""
        let preference = MenuBarMetricPreference(rawValue: raw) ?? .automatic
        if preference == .average, !self.menuBarMetricSupportsAverage(for: provider) {
            return .automatic
        }
        if preference == .tertiary, !self.menuBarMetricSupportsTertiary(for: provider) {
            return .automatic
        }
        return preference
    }

    func setMenuBarMetricPreference(_ preference: MenuBarMetricPreference, for provider: UsageProvider) {
        if provider == .openrouter {
            switch preference {
            case .automatic, .primary:
                self.menuBarMetricPreferencesRaw[provider.rawValue] = preference.rawValue
            case .secondary, .average, .tertiary:
                self.menuBarMetricPreferencesRaw[provider.rawValue] = MenuBarMetricPreference.automatic.rawValue
            }
            return
        }
        if preference == .tertiary, !self.menuBarMetricSupportsTertiary(for: provider) {
            self.menuBarMetricPreferencesRaw[provider.rawValue] = MenuBarMetricPreference.automatic.rawValue
            return
        }
        self.menuBarMetricPreferencesRaw[provider.rawValue] = preference.rawValue
    }

    func menuBarMetricSupportsAverage(for provider: UsageProvider) -> Bool {
        provider == .gemini
    }

    func menuBarMetricSupportsTertiary(for provider: UsageProvider) -> Bool {
        provider == .cursor || provider == .perplexity || provider == .zai
    }

    func menuBarMetricSupportsTertiary(for provider: UsageProvider, snapshot: UsageSnapshot?) -> Bool {
        if provider == .cursor || provider == .zai {
            return snapshot?.tertiary != nil
        }
        return self.menuBarMetricSupportsTertiary(for: provider)
    }

    func menuBarMetricPreference(for provider: UsageProvider, snapshot: UsageSnapshot?) -> MenuBarMetricPreference {
        let preference = self.menuBarMetricPreference(for: provider)
        if preference == .tertiary,
           !self.menuBarMetricSupportsTertiary(for: provider, snapshot: snapshot)
        {
            return .automatic
        }
        return preference
    }

    func isCostUsageEffectivelyEnabled(for provider: UsageProvider) -> Bool {
        self.costUsageEnabled
            && ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost
    }

    var resetTimeDisplayStyle: ResetTimeDisplayStyle {
        self.resetTimesShowAbsolute ? .absolute : .countdown
    }
}
