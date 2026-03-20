import CodexBarCore
import Foundation

extension SettingsStore {
    func menuBarIconTopLane(for provider: UsageProvider) -> MenuBarIconLane {
        if provider == .zai { return .primary }
        let raw = self.menuBarIconTopLanePreferencesRaw[provider.rawValue] ?? ""
        let parsed = MenuBarIconLane(rawValue: raw) ?? .automatic
        return self.clampedTopLane(parsed, for: provider)
    }

    func menuBarIconBottomLane(for provider: UsageProvider) -> MenuBarIconLane {
        if provider == .zai { return .secondary }
        let raw = self.menuBarIconBottomLanePreferencesRaw[provider.rawValue] ?? ""
        let parsed = MenuBarIconLane(rawValue: raw) ?? .automatic
        return self.clampedBottomLane(parsed, for: provider)
    }

    func setMenuBarIconTopLane(_ lane: MenuBarIconLane, for provider: UsageProvider) {
        if provider == .zai {
            self.menuBarIconTopLanePreferencesRaw[provider.rawValue] = MenuBarIconLane.primary.rawValue
            return
        }
        let clamped = self.clampedTopLane(lane, for: provider)
        self.menuBarIconTopLanePreferencesRaw[provider.rawValue] = clamped.rawValue
        self.syncLegacyMenuBarMetricPreference(for: provider, topLane: clamped)
    }

    func setMenuBarIconBottomLane(_ lane: MenuBarIconLane, for provider: UsageProvider) {
        if provider == .zai {
            self.menuBarIconBottomLanePreferencesRaw[provider.rawValue] = MenuBarIconLane.secondary.rawValue
            return
        }
        let clamped = self.clampedBottomLane(lane, for: provider)
        self.menuBarIconBottomLanePreferencesRaw[provider.rawValue] = clamped.rawValue
    }

    /// Legacy single control; sets top + default companion bottom (tests and older call sites).
    func menuBarMetricPreference(for provider: UsageProvider) -> MenuBarMetricPreference {
        if provider == .zai { return .primary }
        if provider == .openrouter {
            return self.menuBarIconTopLane(for: provider) == .primary ? .primary : .automatic
        }
        let top = self.menuBarIconTopLane(for: provider)
        switch top {
        case .none:
            return .automatic
        case .automatic:
            return .automatic
        case .primary:
            return .primary
        case .secondary:
            return .secondary
        case .tertiary:
            return .tertiary
        case .average:
            return .average
        }
    }

    func setMenuBarMetricPreference(_ preference: MenuBarMetricPreference, for provider: UsageProvider) {
        if provider == .zai {
            self.menuBarIconTopLanePreferencesRaw[provider.rawValue] = MenuBarIconLane.primary.rawValue
            self.menuBarIconBottomLanePreferencesRaw[provider.rawValue] = MenuBarIconLane.secondary.rawValue
            self.menuBarMetricPreferencesRaw[provider.rawValue] = MenuBarMetricPreference.primary.rawValue
            return
        }
        if provider == .openrouter {
            switch preference {
            case .automatic, .primary:
                let top: MenuBarIconLane = preference == .primary ? .primary : .automatic
                self.setMenuBarIconTopLane(top, for: provider)
                self.setMenuBarIconBottomLane(
                    MenuBarIconLane.inferredLegacyCompanion(for: preference, provider: provider),
                    for: provider)
            case .secondary, .average, .tertiary:
                self.setMenuBarIconTopLane(.automatic, for: provider)
                self.setMenuBarIconBottomLane(.primary, for: provider)
            }
            return
        }
        let topLane: MenuBarIconLane = switch preference {
        case .automatic: .automatic
        case .primary: .primary
        case .secondary: .secondary
        case .tertiary: .tertiary
        case .average: .average
        }
        let clampedTop = self.clampedTopLane(topLane, for: provider)
        self.menuBarIconTopLanePreferencesRaw[provider.rawValue] = clampedTop.rawValue
        let companionMetric = self.menuBarMetricPreferenceFromLanes(top: clampedTop)
        let bottom = MenuBarIconLane.inferredLegacyCompanion(for: companionMetric, provider: provider)
        let clampedBottom = self.clampedBottomLane(bottom, for: provider)
        self.menuBarIconBottomLanePreferencesRaw[provider.rawValue] = clampedBottom.rawValue
        self.syncLegacyMenuBarMetricPreference(for: provider, topLane: clampedTop)
    }

    func menuBarMetricSupportsAverage(for provider: UsageProvider) -> Bool {
        provider == .gemini
    }

    func menuBarMetricSupportsTertiary(for provider: UsageProvider) -> Bool {
        provider == .cursor
    }

    func isCostUsageEffectivelyEnabled(for provider: UsageProvider) -> Bool {
        self.costUsageEnabled
            && ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost
    }

    var resetTimeDisplayStyle: ResetTimeDisplayStyle {
        self.resetTimesShowAbsolute ? .absolute : .countdown
    }

    // MARK: - Private

    private func menuBarMetricPreferenceFromLanes(top: MenuBarIconLane) -> MenuBarMetricPreference {
        switch top {
        case .none: .automatic
        case .automatic: .automatic
        case .primary: .primary
        case .secondary: .secondary
        case .tertiary: .tertiary
        case .average: .average
        }
    }

    private func syncLegacyMenuBarMetricPreference(for provider: UsageProvider, topLane: MenuBarIconLane) {
        let metric: MenuBarMetricPreference = if provider == .openrouter {
            switch topLane {
            case .primary: .primary
            default: .automatic
            }
        } else {
            self.menuBarMetricPreferenceFromLanes(top: topLane)
        }
        self.menuBarMetricPreferencesRaw[provider.rawValue] = metric.rawValue
    }

    private func clampedTopLane(_ lane: MenuBarIconLane, for provider: UsageProvider) -> MenuBarIconLane {
        if provider == .openrouter {
            switch lane {
            case .automatic, .primary: return lane
            case .secondary, .tertiary, .average, .none: return .automatic
            }
        }
        if lane == .average, !self.menuBarMetricSupportsAverage(for: provider) {
            return .automatic
        }
        if lane == .tertiary, !self.menuBarMetricSupportsTertiary(for: provider) {
            return .automatic
        }
        if lane == .none {
            return .automatic
        }
        return lane
    }

    private func clampedBottomLane(_ lane: MenuBarIconLane, for provider: UsageProvider) -> MenuBarIconLane {
        if provider == .openrouter {
            switch lane {
            case .none, .automatic, .primary: return lane
            case .secondary, .tertiary, .average: return .none
            }
        }
        if lane == .average, !self.menuBarMetricSupportsAverage(for: provider) {
            return .automatic
        }
        if lane == .tertiary, !self.menuBarMetricSupportsTertiary(for: provider) {
            return .automatic
        }
        return lane
    }
}
