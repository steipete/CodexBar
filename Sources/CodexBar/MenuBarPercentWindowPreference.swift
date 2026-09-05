import CodexBarCore
import Foundation

/// Which quota window the menu bar percent reads from, expressed as a single choice.
///
/// The menu bar renders from a `MenuBarLayout`, whose `%` tokens each carry their own
/// `PercentWindow`. That is expressive but only reachable through the layout editor, so an account
/// whose stored preference resolves to the weekly lane can end up showing a nearly-full weekly
/// percent with no obvious way to switch to the session lane. This maps the common case — every
/// percent in the layout reading the same window — onto one picker.
///
/// Only top-level percent tokens are considered. A conditional token carries its own then/else
/// tokens, which stay under the layout editor's control: a layout whose percent lives inside a
/// conditional reports no single preference, so the picker hides rather than silently rewriting
/// half of it.
enum MenuBarPercentWindowPreference: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case session
    case weekly

    var id: String {
        self.rawValue
    }

    var percentWindow: PercentWindow {
        switch self {
        case .automatic: .automatic
        case .session: .session
        case .weekly: .weekly
        }
    }

    var label: String {
        switch self {
        case .automatic: L("menu_bar_layout_token_auto")
        case .session: L("menu_bar_layout_token_session")
        case .weekly: L("menu_bar_layout_token_weekly")
        }
    }

    /// Windows this provider can actually render as a menu-bar percent, in picker order.
    ///
    /// Extra-rate and plan metrics (monthly plan, extra usage, tertiary, average) still resolve
    /// through Automatic — they do not invent a session/weekly lane the snapshot cannot feed.
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
        return Self.allCases.filter { windows.contains($0.percentWindow) }
    }

    static func available(for provider: UsageProvider) -> [Self] {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        return Self.available(
            metrics: descriptor.menuBarMetrics,
            primarySemanticWindow: descriptor.presentation.primarySemanticWindow,
            secondarySemanticWindow: descriptor.presentation.secondarySemanticWindow)
    }

    /// The simplified picker is a percent-layout control. Critters and Bars keep their global style,
    /// and a single remaining option (or no session/weekly lane at all) is not worth a dead control.
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
            available: self.available(for: provider))
    }

    /// Writes the per-provider layout override without flipping `menuBarIconStyle`.
    @MainActor
    static func persist(
        _ preference: Self,
        appliedTo layout: MenuBarLayout,
        for provider: UsageProvider,
        settings: SettingsStore)
    {
        settings.setMenuBarLayout(preference.applied(to: layout), for: provider)
    }

    /// The preference a layout expresses, or nil when its percent tokens mix windows — a
    /// combination only the layout editor can describe, which the picker must not silently flatten.
    static func current(in layout: MenuBarLayout) -> Self? {
        let windows = Self.percentWindows(in: layout)
        guard let first = windows.first, windows.allSatisfy({ $0 == first }) else { return nil }
        return Self.allCases.first { $0.percentWindow == first }
    }

    /// True when the layout shows a percent at all. A layout built from icon-only or reset-time
    /// tokens has nothing for this preference to act on.
    static func hasPercentToken(in layout: MenuBarLayout) -> Bool {
        !self.percentWindows(in: layout).isEmpty
    }

    /// Layout with every percent token pointed at this preference's window; all other tokens,
    /// including line breaks and separators, are left exactly as the user arranged them.
    func applied(to layout: MenuBarLayout) -> MenuBarLayout {
        MenuBarLayout(lines: layout.lines.map { line in
            line.map { token in
                if case .percent = token {
                    return .percent(window: self.percentWindow)
                }
                return token
            }
        })
    }

    private static func percentWindows(in layout: MenuBarLayout) -> [PercentWindow] {
        layout.lines.flatMap(\.self).compactMap { token in
            guard case let .percent(window) = token else { return nil }
            return window
        }
    }

    /// Same mapping the layout migration uses: primary/secondary become the provider's semantic
    /// session or weekly lane; every other metric, including monthly plan, stays on Automatic.
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
