import CodexBarCore
import Foundation

enum PercentWindow: String, CaseIterable, Codable, Hashable, Sendable {
    case session
    case weekly
    case scopedWeekly
    case automatic
}

enum MenuBarLayoutLane: String, CaseIterable, Codable, Hashable, Sendable {
    case primary
    case secondary
    case tertiary

    static func available(for provider: UsageProvider?, snapshot: UsageSnapshot? = nil) -> [Self] {
        guard let provider else { return [] }
        let capabilities = ProviderDescriptorRegistry.descriptor(for: provider).menuBarMetrics
        return Self.allCases.filter { lane in
            guard capabilities.supports(lane.providerMetric) else { return false }
            return lane != .tertiary || !capabilities.tertiaryRequiresWindow || snapshot?.tertiary != nil
        }
    }

    private var providerMetric: ProviderMenuBarMetric {
        switch self {
        case .primary: .primary
        case .secondary: .secondary
        case .tertiary: .tertiary
        }
    }
}

struct MenuBarLayoutLaneLabels: Hashable {
    let primary: String
    let secondary: String
    let tertiary: String

    init(provider: UsageProvider, snapshot: UsageSnapshot?) {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let labels = snapshot.map {
            descriptor.presentation.rateWindowLabels(metadata: descriptor.metadata, snapshot: $0)
        }
        self.primary = L(labels?.primary ?? descriptor.metadata.sessionLabel)
        self.secondary = L(labels?.secondary ?? descriptor.metadata.weeklyLabel)
        self.tertiary = L(labels?.tertiary ?? descriptor.metadata.opusLabel ?? "Tertiary")
    }

    func label(for lane: MenuBarLayoutLane) -> String {
        switch lane {
        case .primary: self.primary
        case .secondary: self.secondary
        case .tertiary: self.tertiary
        }
    }
}

enum MenuBarLayoutToken: Codable, Hashable, Sendable {
    case icon
    case providerName
    case accountLabel
    case percent(window: PercentWindow)
    case lanePercent(lane: MenuBarLayoutLane)
    /// Signed pace delta for a window, e.g. `+11%` when usage runs ahead of the sustainable rate.
    /// `runsOut` answers "when does this end"; this token answers "how far off the even rate am I".
    case pace(window: PercentWindow)
    case usageBar
    case resetCountdown
    case resetAbsolute
    case runsOut
    case runsOutCompact
    case balance
    case costToday
    case cost30d
    case separatorDot
    case space

    var selectedLane: MenuBarLayoutLane? {
        if case let .lanePercent(lane) = self { return lane }
        return nil
    }

    /// Maps `lanePercent` onto tokens a 0.53.x decoder already understands so a downgrade keeps a
    /// layout instead of dropping the whole blob. Direct lanes follow the provider's semantic
    /// windows: Kimi's primary is weekly, so a Kimi override does not swap 7-day and 5-hour.
    func legacyCompatible(for provider: UsageProvider? = nil) -> MenuBarLayoutToken {
        switch self {
        case let .lanePercent(lane):
            .percent(window: MenuBarLayout.legacyPercentWindow(for: lane, provider: provider))
        default:
            self
        }
    }
}

enum MenuBarLayoutSemanticWindowResolver {
    static func windows(
        provider: UsageProvider,
        snapshot: UsageSnapshot?)
        -> (session: RateWindow?, weekly: RateWindow?)
    {
        guard let snapshot else { return (nil, nil) }
        let windows = ProviderDescriptorRegistry.descriptor(for: provider).presentation
            .semanticWindows(snapshot: snapshot)
        return (windows.session, windows.weekly)
    }

    /// The active model-scoped weekly carve-out (e.g. Claude's `claude-weekly-scoped-fable`
    /// "Fable only" window), if the snapshot exposes one. Kept generic across models: keys off
    /// the `claude-weekly-scoped-` id prefix rather than a specific model name, so it keeps
    /// working when the promotional window rotates to a different model.
    ///
    /// When more than one scoped weekly window is active, the most constrained one (highest
    /// used percentage) wins: that is the limit the user is closest to hitting and the one
    /// worth showing in the always-visible menu bar. The full `NamedRateWindow` is returned so
    /// callers can label the token with the active model instead of assuming Fable.
    static func scopedWeeklyNamedWindow(snapshot: UsageSnapshot?) -> NamedRateWindow? {
        guard let snapshot else { return nil }
        return (snapshot.extraRateWindows ?? [])
            .filter { $0.id.hasPrefix("claude-weekly-scoped-") && !$0.window.isSyntheticPlaceholder }
            .max { $0.window.usedPercent < $1.window.usedPercent }
    }
}

enum MenuBarLayoutBalanceResolver {
    static func balance(
        provider: UsageProvider,
        snapshot: UsageSnapshot?)
        -> String?
    {
        // Provider-specific by design: only OpenRouter exposes its credit balance as the "Remaining" detail row.
        guard provider == .openrouter else { return nil }
        return snapshot?.detailRow(label: "Remaining")?.value
    }
}

enum MenuBarLayoutCostResolver {
    static func todayCostUSD(
        snapshot: CostUsageTokenSnapshot?,
        now: Date,
        calendar: Calendar = .current)
        -> Double?
    {
        guard let snapshot else { return nil }
        return CostUsageTokenSnapshot.entry(
            in: snapshot.daily,
            forLocalDayContaining: now,
            calendar: calendar)?.costUSD
    }
}

struct MenuBarLayout: Codable, Hashable, Sendable {
    static let defaultLayout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])

    let lines: [[MenuBarLayoutToken]]

    init(lines: [[MenuBarLayoutToken]]) {
        self.lines = Self.normalizedLines(lines)
    }

    private enum CodingKeys: String, CodingKey {
        case lines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(lines: container.decode([[MenuBarLayoutToken]].self, forKey: .lines))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.lines, forKey: .lines)
    }

    private static func normalizedLines(_ lines: [[MenuBarLayoutToken]]) -> [[MenuBarLayoutToken]] {
        guard let firstContentLine = lines.firstIndex(where: { !$0.isEmpty }) else {
            return self.defaultLayout.lines
        }
        return Array(lines[firstContentLine...].prefix(2))
    }

    var selectedLanes: Set<MenuBarLayoutLane> {
        Set(self.lines.joined().compactMap(\.selectedLane))
    }

    func legacyCompatible(for provider: UsageProvider? = nil) -> MenuBarLayout {
        MenuBarLayout(lines: self.lines.map { line in
            line.map { $0.legacyCompatible(for: provider) }
        })
    }
}

enum MenuBarLayoutUserDefaultsKey {
    static let layout = "menuBarLayout"
    static let layoutCurrent = "menuBarLayoutV2"
    static let overrides = "menuBarLayoutOverrides"
    static let overridesCurrent = "menuBarLayoutOverridesV2"
}

enum MenuBarLayoutPreset: String, CaseIterable, Identifiable, Sendable {
    case iconAndPercent
    case iconOnly
    case percentAndReset
    case compactStacked
    case custom

    var id: String {
        self.rawValue
    }

    var layout: MenuBarLayout? {
        switch self {
        case .iconAndPercent:
            MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])
        case .iconOnly:
            MenuBarLayout(lines: [[.icon]])
        case .percentAndReset:
            MenuBarLayout(lines: [[
                .icon,
                .percent(window: .automatic),
                .separatorDot,
                .resetCountdown,
            ]])
        case .compactStacked:
            MenuBarLayout(lines: [
                [.percent(window: .session)],
                [.percent(window: .weekly)],
            ])
        case .custom:
            nil
        }
    }

    static func matching(_ layout: MenuBarLayout) -> Self {
        allCases.first { $0.layout == layout } ?? .custom
    }
}

enum MenuBarLayoutSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case regular

    var id: String {
        self.rawValue
    }
}

enum MenuBarLayoutGap: String, CaseIterable, Identifiable, Sendable {
    case tight
    case regular

    var id: String {
        self.rawValue
    }
}

struct MenuBarLayoutResolution: Equatable {
    struct LegacySettings: Equatable {
        let iconStyle: MenuBarIconStyle
        let displayMode: MenuBarDisplayMode
        let metricPreference: MenuBarMetricPreference
        let resetTimeDisplayStyle: ResetTimeDisplayStyle
    }

    let layout: MenuBarLayout
    let legacySettings: LegacySettings?

    var usesLegacyRendering: Bool {
        self.legacySettings != nil
    }

    static func stored(_ layout: MenuBarLayout) -> Self {
        Self(layout: layout, legacySettings: nil)
    }

    static func legacy(
        iconStyle: MenuBarIconStyle,
        displayMode: MenuBarDisplayMode,
        metricPreference: MenuBarMetricPreference,
        resetTimeDisplayStyle: ResetTimeDisplayStyle,
        provider: UsageProvider? = nil)
        -> Self
    {
        Self(
            layout: MenuBarLayout.migrated(
                iconStyle: iconStyle,
                displayMode: displayMode,
                metricPreference: metricPreference,
                resetTimeDisplayStyle: resetTimeDisplayStyle,
                provider: provider),
            legacySettings: LegacySettings(
                iconStyle: iconStyle,
                displayMode: displayMode,
                metricPreference: metricPreference,
                resetTimeDisplayStyle: resetTimeDisplayStyle))
    }
}

extension MenuBarLayout {
    static func migrated(
        iconStyle: MenuBarIconStyle,
        displayMode: MenuBarDisplayMode,
        metricPreference: MenuBarMetricPreference,
        resetTimeDisplayStyle: ResetTimeDisplayStyle,
        provider: UsageProvider? = nil)
        -> MenuBarLayout
    {
        _ = iconStyle // Critters and bars keep rendering through their unchanged legacy path.
        let icon: MenuBarLayoutToken = .icon
        // Provider-specific by design: OpenRouter Automatic historically renders remaining credit balance.
        if provider == .openrouter, metricPreference == .automatic {
            return MenuBarLayout(lines: [[icon, .balance]])
        }
        switch displayMode {
        case .percent:
            if metricPreference == .primaryAndSecondary {
                return MenuBarLayout(lines: [[
                    icon,
                    .percent(window: Self.percentWindow(for: .primary, provider: provider)),
                    .separatorDot,
                    .percent(window: Self.percentWindow(for: .secondary, provider: provider)),
                ]])
            }
            return MenuBarLayout(lines: [[
                icon,
                .percent(window: Self.percentWindow(for: metricPreference, provider: provider)),
            ]])
        case .pace:
            return MenuBarLayout(lines: [[icon, .runsOut]])
        case .both:
            return MenuBarLayout(lines: [[
                icon,
                .percent(window: Self.percentWindow(for: metricPreference, provider: provider)),
                .separatorDot,
                .runsOut,
            ]])
        case .resetTime:
            let resetItem = resetTimeDisplayStyle == .absolute
                ? MenuBarLayoutToken.resetAbsolute
                : MenuBarLayoutToken.resetCountdown
            return MenuBarLayout(lines: [[icon, resetItem]])
        }
    }

    private static func percentWindow(
        for preference: MenuBarMetricPreference,
        provider: UsageProvider?)
        -> PercentWindow
    {
        switch preference {
        case .primary:
            self.percentWindow(
                ProviderDescriptorRegistry.descriptor(for: provider ?? .codex).presentation.primarySemanticWindow)
        case .secondary:
            self.percentWindow(
                ProviderDescriptorRegistry.descriptor(for: provider ?? .codex).presentation.secondarySemanticWindow)
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

    static func legacyPercentWindow(for lane: MenuBarLayoutLane, provider: UsageProvider?) -> PercentWindow {
        switch lane {
        case .primary: self.percentWindow(for: .primary, provider: provider)
        case .secondary: self.percentWindow(for: .secondary, provider: provider)
        case .tertiary: .automatic
        }
    }
}

enum MenuBarLayoutPersistence {
    static func preferredLayout(current: MenuBarLayout?, legacy: MenuBarLayout?) -> MenuBarLayout? {
        if let current {
            if let legacy, current.legacyCompatible() != legacy {
                return legacy
            }
            return current
        }
        return legacy
    }

    static func preferredOverrides(
        current: [String: MenuBarLayout]?,
        legacy: [String: MenuBarLayout]?)
        -> [String: MenuBarLayout]
    {
        guard let current else { return legacy ?? [:] }
        guard let legacy else { return current }
        guard Self.overridesAgree(current: current, legacy: legacy) else {
            return legacy
        }
        return current
    }

    static func overridesAgree(
        current: [String: MenuBarLayout],
        legacy: [String: MenuBarLayout])
        -> Bool
    {
        guard Set(current.keys) == Set(legacy.keys) else { return false }
        return current.allSatisfy { key, layout in
            layout.legacyCompatible(for: UsageProvider(rawValue: key)) == legacy[key]
        }
    }
}
