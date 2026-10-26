import CodexBarCore
import Foundation

/// Maps the layout's common top-level percentage tokens onto one picker. Conditional branches
/// and direct primary/secondary lane tokens remain under the layout editor's control.
enum MenuBarPercentWindowPreference: Hashable, Identifiable, Sendable {
    case automatic
    case session
    case weekly
    case tertiary
    case monthlyPlan
    case extra(id: String)

    static let standardChoices: [Self] = [.automatic, .session, .weekly, .tertiary, .monthlyPlan]

    var id: String {
        if case let .extra(id) = self { return "extra:\(id)" }
        return String(describing: self)
    }

    private var percentWindow: PercentWindow? {
        switch self {
        case .automatic: .automatic
        case .session: .session
        case .weekly: .weekly
        case .tertiary, .monthlyPlan, .extra: nil
        }
    }

    private var layoutToken: MenuBarLayoutToken {
        if self == .tertiary { return .lanePercent(lane: .tertiary) }
        if case let .extra(id) = self { return .extraPercent(id: id) }
        // Metric-backed choices resolve through the automatic lane.
        return .percent(window: self.percentWindow ?? .automatic)
    }

    /// The per-provider metric this choice stores for providers that offer Monthly Plan, which the
    /// automatic percent and widgets read.
    var menuBarMetric: MenuBarMetricPreference {
        self == .monthlyPlan ? .monthlyPlan : .automatic
    }

    func label(for provider: UsageProvider?, snapshot: UsageSnapshot? = nil) -> String {
        guard let provider else {
            return switch self {
            case .automatic, .monthlyPlan: L("menu_bar_layout_token_auto")
            case .session: snapshot?.primary?.title ?? L("Primary")
            case .weekly: snapshot?.secondary?.title ?? L("Secondary")
            case .tertiary: snapshot?.tertiary?.title ?? L("Tertiary")
            case let .extra(id): snapshot?.extraRateWindows?.first { $0.id == id }?.title ?? id
            }
        }
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        if case let .extra(id) = self { return descriptor.menuBarMetrics.namedExtras[id].map(L) ?? L("Usage") }
        guard self != .automatic else { return L("menu_bar_layout_token_auto") }
        if self == .monthlyPlan { return MenuBarMetricPreference.monthlyPlan.label }
        if self == .tertiary {
            return MenuBarLayoutLaneLabels(provider: provider, snapshot: snapshot).label(for: .tertiary)
        }
        let primary = PercentWindow.forSemanticWindow(descriptor.presentation.primarySemanticWindow)
        let presentation = descriptor.presentation
        let labels = MenuBarLayoutLaneLabels(provider: provider, snapshot: snapshot)
        return self.percentWindow == primary
            ? presentation.menuBarLayoutPrimaryLabel.map(L) ?? labels.primary
            : presentation.menuBarLayoutSecondaryLabel.map(L) ?? labels.secondary
    }

    /// Semantic windows keep their existing mapping; an independently selectable tertiary pool
    /// uses the already-supported direct lane token and its provider-owned label.
    static func available(
        metrics: ProviderMenuBarMetricCapabilities,
        primarySemanticWindow: ProviderSemanticWindow = .session,
        secondarySemanticWindow: ProviderSemanticWindow = .weekly) -> [Self]
    {
        var windows = Set<PercentWindow>()
        for metric in metrics.supported {
            windows.insert(PercentWindow.forMetric(
                metric,
                primarySemanticWindow: primarySemanticWindow,
                secondarySemanticWindow: secondarySemanticWindow))
        }
        var options = Self.standardChoices.filter { preference in
            guard let window = preference.percentWindow else { return false }
            return windows.contains(window)
        }
        if metrics.supported.contains(.tertiary), !metrics.tertiaryRequiresWindow {
            options.append(.tertiary)
        }
        if metrics.supported.contains(.monthlyPlan) {
            options.append(.monthlyPlan)
        }
        return options + metrics.namedExtras.keys.sorted().map { .extra(id: $0) }
    }

    static func availableForPlugin(snapshot: UsageSnapshot?, layout: MenuBarLayout) -> [Self] {
        var options: [Self] = [.automatic, .session, .weekly, .tertiary]
        options += (snapshot?.extraRateWindows ?? []).map { .extra(id: $0.id) }
        // Preserve a selected extra across missing snapshots; rendering falls back to Automatic.
        if let selected = Self.current(in: layout), !options.contains(selected) {
            options.append(selected)
        }
        return options
    }

    static func available(for provider: UsageProvider, layout: MenuBarLayout? = nil) -> [Self] {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        var options = Self.available(
            metrics: descriptor.menuBarMetrics,
            primarySemanticWindow: descriptor.presentation.primarySemanticWindow,
            secondarySemanticWindow: descriptor.presentation.secondarySemanticWindow)
        if let layout, !self.percentWindows(in: layout).isEmpty, self.hasTertiaryPercent(in: layout) {
            options.removeAll { $0 == .tertiary }
        }
        if let layout, self.hasIndependentPercents(in: layout) {
            if self.percentWindows(in: layout).isEmpty, !self.hasTertiaryPercent(in: layout) { return [] }
            options.removeAll { preference in
                if case .extra = preference { return true }
                return false
            }
        }
        // Without a percentage in the layout, only the stored metric can change.
        if let layout, options.contains(.monthlyPlan), !self.hasPercentToken(in: layout) {
            return [.automatic, .monthlyPlan]
        }
        return options
    }

    /// The simplified picker controls percent layouts without changing the global icon style.
    /// Monthly Plan also picks the widget allowance, so it stays reachable in every style and layout.
    static func isVisible(
        iconStyle: MenuBarIconStyle,
        layout: MenuBarLayout,
        available: [Self]) -> Bool
    {
        guard available.count > 1 else { return false }
        if available.contains(.monthlyPlan) { return true }
        return iconStyle == .iconAndPercent && self.hasPercentToken(in: layout)
    }

    static func isVisible(
        iconStyle: MenuBarIconStyle,
        layout: MenuBarLayout,
        provider: UsageProvider) -> Bool
    {
        self.isVisible(
            iconStyle: iconStyle,
            layout: layout,
            available: self.available(for: provider, layout: layout))
    }

    /// Ordinary percentages own the choice when a custom layout also has an independent tertiary
    /// token. Only layouts without ordinary percentages treat tertiary tokens as the controlled group.
    /// Pass the stored metric for providers that offer Monthly Plan: it turns an all-automatic layout into the
    /// Monthly Plan choice, and alone decides the choice when the layout has no percentage.
    static func current(in layout: MenuBarLayout, metric: MenuBarMetricPreference? = nil) -> Self? {
        let windows = Self.percentWindows(in: layout)
        guard let first = windows.first else {
            if self.hasTertiaryPercent(in: layout) { return .tertiary }
            let extras = self.extraIDs(in: layout)
            if let id = extras.first {
                return extras.allSatisfy { $0 == id } ? .extra(id: id) : nil
            }
            guard let metric else { return nil }
            return metric == .monthlyPlan ? .monthlyPlan : .automatic
        }
        guard windows.allSatisfy({ $0 == first }) else { return nil }
        if first == .automatic, metric == .monthlyPlan { return .monthlyPlan }
        return Self.standardChoices.first { $0.percentWindow == first }
    }

    static func hasPercentToken(in layout: MenuBarLayout) -> Bool {
        !self.percentWindows(in: layout).isEmpty || self.hasTertiaryPercent(in: layout)
            || !self.extraIDs(in: layout).isEmpty
    }

    /// Changes only the common percentage group, preserving pace, resets and custom tokens.
    func applied(to layout: MenuBarLayout) -> MenuBarLayout {
        let hasOrdinaryPercent = !Self.percentWindows(in: layout).isEmpty
        let hasTertiary = Self.hasTertiaryPercent(in: layout)
        // Collapsing an ordinary percent and an independent tertiary token would lose their identities.
        if self == .tertiary, hasOrdinaryPercent, hasTertiary { return layout }
        if Self.hasIndependentPercents(in: layout) {
            if !hasOrdinaryPercent, !hasTertiary { return layout }
            if case .extra = self { return layout }
        }
        return MenuBarLayout(lines: layout.lines.map { line in
            line.map { token in
                if case let .percent(window) = token, window != .spend { return self.layoutToken }
                if !hasOrdinaryPercent, token == .lanePercent(lane: .tertiary) { return self.layoutToken }
                if !hasOrdinaryPercent, !hasTertiary, case .extraPercent = token { return self.layoutToken }
                return token
            }
        })
    }

    private static func hasTertiaryPercent(in layout: MenuBarLayout) -> Bool {
        layout.lines.joined().contains(.lanePercent(lane: .tertiary))
    }

    private static func hasIndependentPercents(in layout: MenuBarLayout) -> Bool {
        let groups = (self.percentWindows(in: layout).isEmpty ? 0 : 1)
            + (self.hasTertiaryPercent(in: layout) ? 1 : 0) + Set(self.extraIDs(in: layout)).count
        return groups > 1
    }

    private static func extraIDs(in layout: MenuBarLayout) -> [String] {
        layout.lines.joined().compactMap { token in
            guard case let .extraPercent(id) = token else { return nil }
            return id
        }
    }

    private static func percentWindows(in layout: MenuBarLayout) -> [PercentWindow] {
        layout.lines.flatMap(\.self).compactMap { token in
            // Spend % is a provider budget, not a quota window: the picker never selects, rewrites or removes it.
            guard case let .percent(window) = token, window != .spend else { return nil }
            return window
        }
    }
}
