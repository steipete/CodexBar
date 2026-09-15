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
/// Only top-level percent tokens are considered, counting the tertiary lane token the Monthly
/// choice writes as its percent. A conditional token carries its own then/else
/// tokens, which stay under the layout editor's control. The picker hides when no top-level percent
/// exists; mixed layouts expose only their top-level percent choice.
enum MenuBarPercentWindowPreference: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case session
    case weekly
    case monthly

    var id: String {
        self.rawValue
    }

    /// Backing window for the automatic/session/weekly choices. Monthly has no PercentWindow;
    /// it renders through the tertiary lane token, so this value is unused for that case.
    var percentWindow: PercentWindow {
        switch self {
        case .automatic: .automatic
        case .session: .session
        case .weekly: .weekly
        // Unused: monthly renders through lanePercent(.tertiary), never a PercentWindow.
        case .monthly: .automatic
        }
    }

    func label(for provider: UsageProvider) -> String {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        switch self {
        case .automatic:
            return L("menu_bar_layout_token_auto")
        case .monthly:
            return L(descriptor.metadata.opusLabel ?? "Monthly")
        case .session, .weekly:
            let primary = Self.percentWindow(descriptor.presentation.primarySemanticWindow)
            return L(self.percentWindow == primary ? descriptor.metadata.sessionLabel : descriptor.metadata.weeklyLabel)
        }
    }

    /// Windows this provider can actually render as a menu-bar percent, in picker order.
    ///
    /// The tertiary metric surfaces as its own Monthly option backed by the tertiary lane token.
    /// Monthly plan, extra usage, and average still resolve through Automatic — they do not invent
    /// a session/weekly lane the snapshot cannot feed.
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
        var options = Self.allCases.filter { $0 != .monthly && windows.contains($0.percentWindow) }
        if metrics.supported.contains(.tertiary) {
            options.append(.monthly)
        }
        return options
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

    /// The preference a layout expresses, or nil when its picker-class percent tokens mix windows —
    /// a combination only the layout editor can describe, which the picker must not silently flatten.
    /// Independent primary/secondary lane tokens are ignored: they stay under the layout editor's
    /// control and must not drag the picker to Custom.
    static func current(in layout: MenuBarLayout) -> Self? {
        var sawMonthly = false
        var windows: [PercentWindow] = []
        for token in layout.lines.flatMap(\.self) {
            switch token {
            case let .percent(window):
                windows.append(window)
            case let .lanePercent(lane):
                if lane == .tertiary {
                    sawMonthly = true
                }
            default:
                continue
            }
        }
        if sawMonthly {
            return windows.isEmpty ? .monthly : nil
        }
        guard let first = windows.first, windows.allSatisfy({ $0 == first }) else { return nil }
        return Self.allCases.first { $0 != .monthly && $0.percentWindow == first }
    }

    /// True when the layout shows a percent at all. A layout built from icon-only or reset-time
    /// tokens has nothing for this preference to act on. Counts the tertiary lane the Monthly
    /// choice writes; other direct lanes stay under the layout editor's control.
    static func hasPercentToken(in layout: MenuBarLayout) -> Bool {
        !self.percentWindows(in: layout).isEmpty || self.hasTertiaryLaneToken(in: layout)
    }

    private static func hasTertiaryLaneToken(in layout: MenuBarLayout) -> Bool {
        layout.lines.flatMap(\.self).contains {
            if case let .lanePercent(lane) = $0 { return lane == .tertiary }
            return false
        }
    }

    /// Layout with this preference's window pointed at the new choice, preserving independent
    /// custom tokens. Percent tokens always follow (the picker's documented contract, including the
    /// flattening of mixed percent windows); pace and lane tokens only follow when they match the
    /// previous selection, so an independently chosen Weekly pace or Monthly percent survives a
    /// picker change. Monthly rewrites percent tokens to the tertiary lane token the renderer reads
    /// for that window, and leaving Monthly rewrites those lane tokens back — otherwise a Monthly
    /// layout would have no percent token left to rewrite and the picker could never leave Monthly.
    func applied(to layout: MenuBarLayout) -> MenuBarLayout {
        let previous = Self.current(in: layout)
        return MenuBarLayout(lines: layout.lines.map { line in
            line.map { token in
                switch token {
                case .percent:
                    if self == .monthly {
                        return .lanePercent(lane: .tertiary)
                    }
                    return .percent(window: self.percentWindow)
                case let .pace(window):
                    if self == .monthly {
                        guard previous == nil || window == previous?.percentWindow else { return token }
                        return .lanePace(lane: .tertiary)
                    }
                    guard let previous, previous != .monthly else { return token }
                    guard window == previous.percentWindow else { return token }
                    return .pace(window: self.percentWindow)
                case let .lanePercent(lane) where lane == .tertiary && self != .monthly:
                    guard previous == .monthly else { return token }
                    return .percent(window: self.percentWindow)
                case let .lanePace(lane) where lane == .tertiary && self != .monthly:
                    guard previous == .monthly else { return token }
                    return .pace(window: self.percentWindow)
                default:
                    return token
                }
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
