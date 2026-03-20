import CodexBarCore
import Foundation

enum MenuBarMetricWindowResolver {
    static func rateWindow(
        preference: MenuBarMetricPreference,
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        supportsAverage: Bool)
        -> RateWindow?
    {
        self.rateWindow(
            lane: MenuBarIconLane(rawValue: preference.rawValue) ?? .automatic,
            provider: provider,
            snapshot: snapshot,
            supportsAverage: supportsAverage)
    }

    static func rateWindow(
        lane: MenuBarIconLane,
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        supportsAverage: Bool)
        -> RateWindow?
    {
        guard let snapshot, lane != .none else { return nil }
        switch lane {
        case .none:
            return nil
        case .tertiary:
            guard provider == .cursor else {
                return snapshot.primary ?? snapshot.secondary
            }
            return snapshot.tertiary ?? snapshot.secondary ?? snapshot.primary
        case .primary:
            return snapshot.primary ?? snapshot.secondary
        case .secondary:
            return snapshot.secondary ?? snapshot.primary
        case .average:
            guard supportsAverage,
                  let primary = snapshot.primary,
                  let secondary = snapshot.secondary
            else {
                return snapshot.primary ?? snapshot.secondary
            }
            let usedPercent = (primary.usedPercent + secondary.usedPercent) / 2
            return RateWindow(usedPercent: usedPercent, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        case .automatic:
            if provider == .factory || provider == .kimi {
                return snapshot.secondary ?? snapshot.primary
            }
            if provider == .copilot,
               let primary = snapshot.primary,
               let secondary = snapshot.secondary
            {
                return primary.usedPercent >= secondary.usedPercent ? primary : secondary
            }
            if provider == .cursor {
                return Self.mostConstrainedWindow(
                    primary: snapshot.primary,
                    secondary: snapshot.secondary,
                    tertiary: snapshot.tertiary)
            }
            return snapshot.primary ?? snapshot.secondary
        }
    }

    /// Second bar when **Automatic** is chosen for the bottom slot (or legacy paired automatic).
    static func secondAutomaticWindow(provider: UsageProvider, snapshot: UsageSnapshot) -> RateWindow? {
        if provider == .factory || provider == .kimi {
            return snapshot.primary
        }
        if provider == .copilot,
           let primaryWin = snapshot.primary,
           let secondaryWin = snapshot.secondary
        {
            let ordered = [primaryWin, secondaryWin].sorted { $0.usedPercent > $1.usedPercent }
            return ordered.count >= 2 ? ordered[1] : nil
        }
        if provider == .cursor {
            let ranked = [snapshot.primary, snapshot.secondary, snapshot.tertiary].compactMap(\.self)
                .sorted { $0.usedPercent > $1.usedPercent }
            return ranked.count >= 2 ? ranked[1] : nil
        }
        return snapshot.secondary
    }

    private static func mostConstrainedWindow(
        primary: RateWindow?,
        secondary: RateWindow?,
        tertiary: RateWindow?)
        -> RateWindow?
    {
        let windows = [primary, secondary, tertiary].compactMap(\.self)
        guard !windows.isEmpty else { return nil }
        return windows.max(by: { $0.usedPercent < $1.usedPercent })
    }
}
