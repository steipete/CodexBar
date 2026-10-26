import CodexBarCore

extension StatusItemController {
    nonisolated static func pluginMeterPercents(snapshot: UsageSnapshot?, showUsed: Bool)
        -> (primary: Double?, secondary: Double?)
    {
        guard let snapshot, snapshot.primary != nil || snapshot.secondary != nil else {
            return (self.pluginSwitcherMetricPercent(snapshot: snapshot, showUsed: showUsed), nil)
        }
        let lanes = IconRemainingResolver.resolvedPercents(snapshot: snapshot, style: .combined, showUsed: showUsed)
        return (
            lanes.primary.map { min(100, max(0, $0)) },
            lanes.secondary.map { min(100, max(0, $0)) })
    }

    nonisolated static func pluginSwitcherMetricPercent(
        snapshot: UsageSnapshot?,
        showUsed: Bool,
        preference: MenuBarPercentWindowPreference = .automatic) -> Double?
    {
        let selected: RateWindow? = switch preference {
        case .session: snapshot?.primary
        case .weekly: snapshot?.secondary
        case .tertiary: snapshot?.tertiary
        case let .extra(id): snapshot?.extraRateWindows?.first { $0.id == id && $0.usageKnown }?.window
        case .automatic, .monthlyPlan: nil
        }
        let availableSelection = selected.flatMap {
            $0.usedPercent.isFinite && !$0.isSyntheticPlaceholder ? $0 : nil
        }
        let windows = ([snapshot?.primary, snapshot?.secondary, snapshot?.tertiary].compactMap(\.self) +
            (snapshot?.extraRateWindows ?? []).filter(\.usageKnown).map(\.window))
            .filter(\.usedPercent.isFinite)
        let weekly = windows.filter { $0.windowMinutes == 7 * 24 * 60 }
            .max { $0.usedPercent < $1.usedPercent }
        guard let window = availableSelection ?? weekly ?? windows.first else { return nil }
        let used = min(100, max(0, window.usedPercent))
        return showUsed ? used : 100 - used
    }

    nonisolated static func switcherWeeklyMetricPercent(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        showUsed: Bool,
        preference: MenuBarMetricPreference = .automatic) -> Double?
    {
        let metric = preference == .automatic || preference == .monthlyPlan
            ? MenuBarMetricWindowResolver.rateWindow(
                preference: preference,
                provider: provider,
                snapshot: snapshot,
                supportsAverage: false)
            : nil
        let presentation = ProviderDescriptorRegistry.descriptor(for: provider).presentation
        let window: RateWindow? = if preference == .monthlyPlan {
            metric
        } else if provider == .mistral {
            nil
        } else if preference == .automatic,
                  let metric,
                  presentation.switcherUsesAutomaticMenuBarWindow
                  || (presentation.automaticSelectionPrioritizesExhaustedWindow && metric.usedPercent >= 100)
        {
            metric
        } else {
            snapshot?.switcherWeeklyWindow(for: provider, showUsed: showUsed)
        }
        if let window {
            return showUsed ? window.usedPercent : window.remainingPercent
        }
        guard preference == .automatic,
              let snapshot,
              let usedPercent = presentation.fallbackSwitcherUsedPercent(snapshot: snapshot),
              usedPercent.isFinite else { return nil }
        return showUsed ? usedPercent : max(0, 100 - usedPercent)
    }
}
