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
        guard let snapshot else { return nil }
        switch preference {
        case .tertiary:
            if provider == .perplexity {
                return snapshot.tertiary ?? snapshot.secondary ?? snapshot.primary
            }
            guard provider == .cursor else {
                if provider == .antigravity {
                    return snapshot.tertiary ?? snapshot.secondary ?? snapshot.primary
                }
                return snapshot.primary ?? snapshot.secondary
            }
            return snapshot.tertiary ?? snapshot.secondary ?? snapshot.primary
        case .primary:
            if provider == .perplexity {
                return snapshot.primary ?? snapshot.secondary ?? snapshot.tertiary
            }
            if provider == .antigravity {
                return snapshot.primary ?? snapshot.secondary ?? snapshot.tertiary
            }
            return snapshot.primary ?? snapshot.secondary
        case .secondary:
            if provider == .perplexity {
                return snapshot.secondary ?? snapshot.tertiary ?? snapshot.primary
            }
            if provider == .antigravity {
                return snapshot.secondary ?? snapshot.primary ?? snapshot.tertiary
            }
            return snapshot.secondary ?? snapshot.primary
        case .average:
            guard supportsAverage,
                  let primary = snapshot.primary,
                  let secondary = snapshot.secondary
            else {
                if provider == .antigravity {
                    return snapshot.primary ?? snapshot.secondary ?? snapshot.tertiary
                }
                return snapshot.primary ?? snapshot.secondary
            }
            let usedPercent = (primary.usedPercent + secondary.usedPercent) / 2
            return RateWindow(usedPercent: usedPercent, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        case .automatic:
            if provider == .antigravity {
                return snapshot.primary ?? snapshot.secondary ?? snapshot.tertiary
            }
            if provider == .perplexity {
                return snapshot.automaticPerplexityWindow()
            }
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
