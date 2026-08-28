import CodexBarCore
import Foundation

enum MenuBarMetricWindowResolver {
    static func rateWindow(
        preference: MenuBarMetricPreference,
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        supportsAverage: Bool,
        antigravityPrioritizeExhaustedQuotas: Bool = false,
        now: Date = Date())
        -> RateWindow?
    {
        guard let snapshot else { return nil }
        let presentation = ProviderDescriptorRegistry.descriptor(for: provider).presentation
        let metric = Self.providerMetric(preference)
        switch presentation.menuBarWindow(context: ProviderMenuBarWindowContext(
            metric: metric,
            snapshot: snapshot,
            supportsAverage: supportsAverage,
            prioritizesExhaustedQuotas: antigravityPrioritizeExhaustedQuotas,
            now: now))
        {
        case let .resolved(window):
            return window
        case .unhandled:
            break
        }
        switch preference {
        case .monthlyPlan:
            return nil
        case .extraUsage:
            return Self.extraUsageWindow(snapshot: snapshot)
        case .tertiary:
            return Self.requestedWindow(
                provider: provider,
                snapshot: snapshot,
                lanes: presentation.requestedMenuBarLaneOrder(for: .tertiary))
        case .primary:
            return Self.requestedWindow(
                provider: provider,
                snapshot: snapshot,
                lanes: presentation.requestedMenuBarLaneOrder(for: .primary))
        case .secondary:
            return Self.requestedWindow(
                provider: provider,
                snapshot: snapshot,
                lanes: presentation.requestedMenuBarLaneOrder(for: .secondary))
        case .primaryAndSecondary:
            // Claude accounts that only expose an enterprise/extra-usage spend limit have no real
            // session/weekly lanes; surface the spend limit (as `.automatic` does) instead of an empty
            // or 0% placeholder lane.
            return Self.mostConstrainedWindow(
                primary: snapshot.primary,
                secondary: snapshot.secondary,
                tertiary: nil)
        case .average:
            return Self.averageWindow(snapshot: snapshot, supportsAverage: supportsAverage)
        case .automatic:
            return Self.automaticWindow(
                presentation: presentation,
                snapshot: snapshot,
                now: now)
        }
    }

    static func automaticSelectionPrioritizesExhaustedWindow(for provider: UsageProvider) -> Bool {
        ProviderDescriptorRegistry.descriptor(for: provider).presentation
            .automaticSelectionPrioritizesExhaustedWindow
    }

    private static func averageWindow(
        snapshot: UsageSnapshot,
        supportsAverage: Bool)
        -> RateWindow?
    {
        guard supportsAverage,
              let primary = snapshot.primary,
              let secondary = snapshot.secondary
        else {
            return snapshot.primary ?? snapshot.secondary
        }

        let usedPercent = (primary.usedPercent + secondary.usedPercent) / 2
        return RateWindow(usedPercent: usedPercent, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
    }

    private static func automaticWindow(
        presentation: ProviderUsagePresentation,
        snapshot: UsageSnapshot,
        now: Date)
        -> RateWindow?
    {
        _ = now
        if presentation.automaticSelectionPrioritizesExhaustedWindow,
           let exhausted = exhaustedWindow(
               primary: snapshot.primary,
               secondary: snapshot.secondary,
               tertiary: snapshot.tertiary)
        {
            return exhausted
        }
        return snapshot.primary ?? snapshot.secondary
    }

    private static func providerMetric(_ preference: MenuBarMetricPreference) -> ProviderMenuBarMetric {
        switch preference {
        case .automatic: .automatic
        case .primary: .primary
        case .secondary: .secondary
        case .primaryAndSecondary: .primaryAndSecondary
        case .tertiary: .tertiary
        case .extraUsage: .extraUsage
        case .average: .average
        case .monthlyPlan: .monthlyPlan
        }
    }

    private static let antigravityQuotaSummaryWindowIDPrefix = "antigravity-quota-summary-"
    /// Picks the binding supported quota-summary lane for the exhausted-first opt-in.
    static func antigravityQuotaSummaryRankingWindow(
        snapshot: UsageSnapshot,
        now: Date)
        -> RateWindow?
    {
        self.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: snapshot,
            supportsAverage: false,
            antigravityPrioritizeExhaustedQuotas: true,
            now: now)
    }

    /// True only when every fully understood quota family has an exhausted binding lane.
    /// Any incomplete or unfamiliar summary row fails open so automatic provider rotation
    /// does not hide quota that CodexBar cannot classify safely.
    static func antigravityQuotaSummaryFamiliesAreAllBlocked(snapshot: UsageSnapshot) -> Bool {
        let rows = Self.antigravityQuotaSummaryRows(snapshot: snapshot)
        guard !rows.isEmpty else { return false }

        var familyBlocked: [String: Bool] = [:]
        for row in rows {
            guard row.usageKnown,
                  row.window.usedPercent.isFinite,
                  Self.isSupportedAntigravityQuotaCadence(row.window.windowMinutes),
                  let family = Self.antigravityQuotaFamily(for: row)
            else {
                return false
            }
            familyBlocked[family, default: false] =
                familyBlocked[family, default: false] || row.window.usedPercent >= 100
        }
        return !familyBlocked.isEmpty && familyBlocked.values.allSatisfy(\.self)
    }

    private static let antigravitySupportedQuotaCadences: Set<Int> = [300, 10080]

    private static func isSupportedAntigravityQuotaCadence(_ windowMinutes: Int?) -> Bool {
        guard let windowMinutes else { return false }
        return Self.antigravitySupportedQuotaCadences.contains(windowMinutes)
    }

    private static func antigravityQuotaSummaryRows(snapshot: UsageSnapshot) -> [NamedRateWindow] {
        snapshot.extraRateWindows?.filter {
            $0.id.hasPrefix(Self.antigravityQuotaSummaryWindowIDPrefix)
        } ?? []
    }

    private static func antigravityQuotaFamily(for row: NamedRateWindow) -> String? {
        let suffix = row.id.dropFirst(Self.antigravityQuotaSummaryWindowIDPrefix.count)
        var normalizedSuffix = suffix
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if normalizedSuffix.hasSuffix(" limit") {
            normalizedSuffix.removeLast(" limit".count)
        }
        let cadenceSuffixes: [String]
        switch row.window.windowMinutes {
        case 300:
            cadenceSuffixes = ["-session", "-5h", "-5-hour", "-five hour", "-five-hour"]
        case 10080:
            cadenceSuffixes = ["-weekly"]
        default:
            return nil
        }

        guard let cadenceSuffix = cadenceSuffixes.first(where: normalizedSuffix.hasSuffix) else {
            return nil
        }
        let family = normalizedSuffix
            .dropLast(cadenceSuffix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !family.isEmpty,
              family.first != "-",
              family.last != "-",
              family.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
        else {
            return nil
        }
        return family
    }

    private static func requestedWindow(
        provider _: UsageProvider,
        snapshot: UsageSnapshot,
        lanes: [ProviderUsageLane]) -> RateWindow?
    {
        ProviderUsagePresentation.window(in: snapshot, following: lanes)
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

    private static func exhaustedWindow(
        primary: RateWindow?,
        secondary: RateWindow?,
        tertiary: RateWindow?)
        -> RateWindow?
    {
        [primary, secondary, tertiary]
            .compactMap(\.self)
            .first { $0.usedPercent >= 100 }
    }

    /// The Claude spend-limit window when the account only exposes an enterprise/extra-usage spend limit
    /// and has no real session/weekly quota lanes (`primary` nil, a `.spendLimit` window, or an explicitly
    /// marked placeholder). Lets the automatic and combined metrics surface the spend limit instead of an empty
    /// or 0% placeholder lane. Returns nil for accounts that expose genuine quota lanes.
    static func claudeSpendLimitWindow(snapshot: UsageSnapshot) -> RateWindow? {
        let presentation = ProviderDescriptorRegistry.descriptor(for: .claude).presentation
        switch presentation.menuBarWindow(context: ProviderMenuBarWindowContext(
            metric: .automatic,
            snapshot: snapshot,
            supportsAverage: false,
            prioritizesExhaustedQuotas: false,
            now: .now))
        {
        case let .resolved(window):
            return window
        case .unhandled:
            return nil
        }
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
