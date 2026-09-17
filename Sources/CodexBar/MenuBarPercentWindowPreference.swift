import CodexBarCore
import Foundation

/// Maps the layout's common top-level percentage tokens onto one picker. Conditional branches
/// and direct primary/secondary lane tokens remain under the layout editor's control.
enum MenuBarPercentWindowPreference: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case session
    case weekly
    case tertiary

    var id: String {
        self.rawValue
    }

    private var percentWindow: PercentWindow? {
        switch self {
        case .automatic: .automatic
        case .session: .session
        case .weekly: .weekly
        case .tertiary: nil
        }
    }

    private var layoutToken: MenuBarLayoutToken {
        switch self {
        case .automatic: .percent(window: .automatic)
        case .session: .percent(window: .session)
        case .weekly: .percent(window: .weekly)
        case .tertiary: .lanePercent(lane: .tertiary)
        }
    }

    func label(for provider: UsageProvider) -> String {
        guard self != .automatic else { return L("menu_bar_layout_token_auto") }
        if self == .tertiary {
            return MenuBarLayoutLaneLabels(provider: provider, snapshot: nil).label(for: .tertiary)
        }
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let primary = Self.percentWindow(descriptor.presentation.primarySemanticWindow)
        return L(self.percentWindow == primary ? descriptor.metadata.sessionLabel : descriptor.metadata.weeklyLabel)
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
            windows.insert(Self.percentWindow(
                for: metric,
                primarySemanticWindow: primarySemanticWindow,
                secondarySemanticWindow: secondarySemanticWindow))
        }
        var options = Self.allCases.filter { preference in
            guard let window = preference.percentWindow else { return false }
            return windows.contains(window)
        }
        if metrics.supported.contains(.tertiary), !metrics.tertiaryRequiresWindow {
            options.append(.tertiary)
        }
        return options
    }

    static func available(for provider: UsageProvider, layout: MenuBarLayout? = nil) -> [Self] {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let options = Self.available(
            metrics: descriptor.menuBarMetrics,
            primarySemanticWindow: descriptor.presentation.primarySemanticWindow,
            secondarySemanticWindow: descriptor.presentation.secondarySemanticWindow)
        if let layout, !self.percentWindows(in: layout).isEmpty, self.hasTertiaryPercent(in: layout) {
            return options.filter { $0 != .tertiary }
        }
        return options
    }

    /// The simplified picker controls percent layouts without changing the global icon style.
    static func isVisible(
        iconStyle: MenuBarIconStyle,
        layout: MenuBarLayout,
        available: [Self]) -> Bool
    {
        iconStyle == .iconAndPercent
            && self.hasPercentToken(in: layout)
            && available.count > 1
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
    static func current(in layout: MenuBarLayout) -> Self? {
        let windows = Self.percentWindows(in: layout)
        guard let first = windows.first else { return self.hasTertiaryPercent(in: layout) ? .tertiary : nil }
        guard windows.allSatisfy({ $0 == first }) else { return nil }
        return Self.allCases.first { $0.percentWindow == first }
    }

    static func hasPercentToken(in layout: MenuBarLayout) -> Bool {
        !self.percentWindows(in: layout).isEmpty || self.hasTertiaryPercent(in: layout)
    }

    /// Changes only the common percentage group, preserving pace, resets and custom tokens.
    func applied(to layout: MenuBarLayout) -> MenuBarLayout {
        let hasOrdinaryPercent = !Self.percentWindows(in: layout).isEmpty
        // Collapsing an ordinary percent and an independent tertiary token would lose their identities.
        if self == .tertiary, hasOrdinaryPercent, Self.hasTertiaryPercent(in: layout) { return layout }
        return MenuBarLayout(lines: layout.lines.map { line in
            line.map { token in
                if case .percent = token { return self.layoutToken }
                if !hasOrdinaryPercent, token == .lanePercent(lane: .tertiary) { return self.layoutToken }
                return token
            }
        })
    }

    private static func hasTertiaryPercent(in layout: MenuBarLayout) -> Bool {
        layout.lines.joined().contains(.lanePercent(lane: .tertiary))
    }

    private static func percentWindows(in layout: MenuBarLayout) -> [PercentWindow] {
        layout.lines.flatMap(\.self).compactMap { token in
            guard case let .percent(window) = token else { return nil }
            return window
        }
    }

    /// Same semantic mapping as layout migration: other metrics retain Automatic as an option.
    private static func percentWindow(
        for metric: ProviderMenuBarMetric,
        primarySemanticWindow: ProviderSemanticWindow,
        secondarySemanticWindow: ProviderSemanticWindow) -> PercentWindow
    {
        switch metric {
        case .primary: self.percentWindow(primarySemanticWindow)
        case .secondary: self.percentWindow(secondarySemanticWindow)
        case .automatic, .primaryAndSecondary, .tertiary, .extraUsage, .average, .monthlyPlan:
            .automatic
        }
    }

    private static func percentWindow(_ window: ProviderSemanticWindow) -> PercentWindow {
        switch window {
        case .session: .session
        case .weekly: .weekly
        }
    }
}
