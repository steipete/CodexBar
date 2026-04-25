import CodexBarCore
import Foundation

enum MenuBarMetricWindowResolver {
    private enum Lane {
        case primary
        case secondary
        case tertiary
    }

    static func rateWindow(
        preference: MenuBarMetricPreference,
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        supportsAverage: Bool)
        -> RateWindow?
    {
        guard let snapshot else { return nil }
        switch preference {
        case .extraUsage:
            return Self.extraUsageWindow(snapshot: snapshot)
        case .tertiary:
            return Self.window(in: snapshot, following: Self.tertiaryOrder(for: provider))
        case .primary:
            return Self.window(in: snapshot, following: Self.primaryOrder(for: provider))
        case .secondary:
            return Self.window(in: snapshot, following: Self.secondaryOrder(for: provider))
        case .average:
            return Self.averageWindow(provider: provider, snapshot: snapshot, supportsAverage: supportsAverage)
        case .automatic:
            return Self.automaticWindow(provider: provider, snapshot: snapshot)
        }
    }

    private static func tertiaryOrder(for provider: UsageProvider) -> [Lane] {
        if provider == .zai {
            return [.tertiary, .primary, .secondary]
        }
        if provider == .perplexity || provider == .cursor || provider == .antigravity {
            return [.tertiary, .secondary, .primary]
        }
        return [.primary, .secondary]
    }

    private static func primaryOrder(for provider: UsageProvider) -> [Lane] {
        if provider == .zai {
            return [.primary, .tertiary, .secondary]
        }
        if provider == .perplexity || provider == .antigravity {
            return [.primary, .secondary, .tertiary]
        }
        return [.primary, .secondary]
    }

    private static func secondaryOrder(for provider: UsageProvider) -> [Lane] {
        if provider == .zai || provider == .antigravity {
            return [.secondary, .primary, .tertiary]
        }
        if provider == .perplexity {
            return [.secondary, .tertiary, .primary]
        }
        return [.secondary, .primary]
    }

    private static func averageWindow(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        supportsAverage: Bool)
        -> RateWindow?
    {
        guard supportsAverage,
              let primary = snapshot.primary,
              let secondary = snapshot.secondary
        else {
            if provider == .antigravity {
                return self.window(in: snapshot, following: [.primary, .secondary, .tertiary])
            }
            return snapshot.primary ?? snapshot.secondary
        }

        let usedPercent = (primary.usedPercent + secondary.usedPercent) / 2
        return RateWindow(usedPercent: usedPercent, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
    }

    private static func automaticWindow(provider: UsageProvider, snapshot: UsageSnapshot) -> RateWindow? {
        if provider == .antigravity {
            return self.window(in: snapshot, following: [.primary, .secondary, .tertiary])
        }
        if provider == .perplexity {
            return snapshot.automaticPerplexityWindow()
        }
        if provider == .zai {
            return self.mostConstrainedWindow(
                primary: snapshot.primary,
                secondary: snapshot.tertiary,
                tertiary: nil) ?? snapshot.secondary
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

    private static func window(in snapshot: UsageSnapshot, following lanes: [Lane]) -> RateWindow? {
        for lane in lanes {
            if let window = self.window(in: snapshot, lane: lane) {
                return window
            }
        }
        return nil
    }

    private static func window(in snapshot: UsageSnapshot, lane: Lane) -> RateWindow? {
        switch lane {
        case .primary:
            snapshot.primary
        case .secondary:
            snapshot.secondary
        case .tertiary:
            snapshot.tertiary
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

    private static func extraUsageWindow(snapshot: UsageSnapshot?) -> RateWindow? {
        guard let cost = snapshot?.providerCost, cost.limit > 0 else { return nil }
        let usedPercent = max(0, min(100, (cost.used / cost.limit) * 100))
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: cost.resetsAt,
            resetDescription: nil)
    }
}
