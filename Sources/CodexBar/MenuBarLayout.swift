import CodexBarCore
import Foundation

enum PercentWindow: String, CaseIterable, Codable, Hashable, Sendable {
    case session
    case weekly
    case scopedWeekly
    case automatic
}

/// Comparison unit of a conditional metric: drives the threshold range, the stepper increment, and the
/// unit label shown next to the threshold field.
enum MenuBarConditionalMetricKind: Sendable {
    case percent
    case signedPercent
    case hours
    case currencyUSD
}

/// What a conditional predicate measures. Persistence keys off the case names, so the first four keep
/// their original spelling: a library written before the metric set grew still decodes unchanged.
/// Declaration order is the editor picker's order: percentages, direct lanes, time to reset, pace,
/// run-out, money.
enum MenuBarConditionalMetric: String, CaseIterable, Codable, Hashable, Sendable {
    case session
    case weekly
    case scopedWeekly
    case automatic
    case primaryLane
    case secondaryLane
    case tertiaryLane
    case sessionResetsIn
    case weeklyResetsIn
    case scopedWeeklyResetsIn
    case automaticResetsIn
    case sessionPace
    case weeklyPace
    case automaticPace
    case runsOutIn
    case balance
    case costToday
    case cost30d

    var kind: MenuBarConditionalMetricKind {
        switch self {
        case .session, .weekly, .scopedWeekly, .automatic,
             .primaryLane, .secondaryLane, .tertiaryLane:
            .percent
        case .sessionPace, .weeklyPace, .automaticPace:
            .signedPercent
        case .sessionResetsIn, .weeklyResetsIn, .scopedWeeklyResetsIn, .automaticResetsIn, .runsOutIn:
            .hours
        case .balance, .costToday, .cost30d:
            .currencyUSD
        }
    }

    /// Whether a used/remaining select applies. Percent windows and lanes expose both readings of the
    /// same window; balance exposes spend against remaining credit. Pace is already signed, and a reset
    /// countdown or a cost total has no complement.
    var supportsDirection: Bool {
        switch self {
        case .session, .weekly, .scopedWeekly, .automatic,
             .primaryLane, .secondaryLane, .tertiaryLane, .balance:
            true
        default:
            false
        }
    }

    var thresholdRange: ClosedRange<Double> {
        switch self.kind {
        case .percent: 0...100
        case .signedPercent: -100...100
        // One year, so no realistic reset or run-out window is clamped.
        case .hours: 0...8760
        case .currencyUSD: 0...1_000_000
        }
    }

    var thresholdStep: Double {
        self.kind == .hours ? 0.5 : 1
    }

    /// Unit shown beside the threshold field and appended in the conditional summary.
    var thresholdUnit: String {
        switch self.kind {
        case .percent, .signedPercent: "%"
        case .hours: "h"
        case .currencyUSD: "USD"
        }
    }
}

enum MenuBarConditionalComparison: String, CaseIterable, Codable, Hashable, Sendable {
    case greaterThan
    case greaterThanOrEqual
    case lessThan
    case lessThanOrEqual

    var symbol: String {
        switch self {
        case .greaterThan: ">"
        case .greaterThanOrEqual: ">="
        case .lessThan: "<"
        case .lessThanOrEqual: "<="
        }
    }

    func evaluate(_ value: Double, _ threshold: Double) -> Bool {
        switch self {
        case .greaterThan: value > threshold
        case .greaterThanOrEqual: value >= threshold
        case .lessThan: value < threshold
        case .lessThanOrEqual: value <= threshold
        }
    }
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

enum MenuBarConditionalCombinator: String, CaseIterable, Codable, Hashable, Sendable {
    case and
    case or
}

/// Which reading of a metric a predicate compares.
enum MenuBarConditionalDirection: String, CaseIterable, Codable, Hashable, Sendable {
    case used
    case remaining
}

struct MenuBarConditionalPredicate: Codable, Hashable, Sendable {
    var metric: MenuBarConditionalMetric
    /// Which reading of `metric` to compare. Normalized back to `.used` when the metric has no
    /// complement, so a stored direction can never contradict the metric.
    var direction: MenuBarConditionalDirection
    var comparison: MenuBarConditionalComparison
    var threshold: Double

    init(
        metric: MenuBarConditionalMetric,
        direction: MenuBarConditionalDirection = .used,
        comparison: MenuBarConditionalComparison,
        threshold: Double)
    {
        self.metric = metric
        self.direction = direction
        self.comparison = comparison
        self.threshold = threshold
    }

    private enum CodingKeys: String, CodingKey {
        case metric, direction, comparison, threshold
    }

    /// Predicates persisted before `direction` existed compared used percentages, so a missing key
    /// decodes as `.used` and keeps its original meaning. The synthesized decoder would instead reject
    /// the whole predicate.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.metric = try container.decode(MenuBarConditionalMetric.self, forKey: .metric)
        self.direction = try container.decodeIfPresent(MenuBarConditionalDirection.self, forKey: .direction)
            ?? .used
        self.comparison = try container.decode(MenuBarConditionalComparison.self, forKey: .comparison)
        self.threshold = try container.decode(Double.self, forKey: .threshold)
    }

    /// Clamps the threshold into the metric's unit range and drops a direction the metric cannot use.
    func normalized() -> Self {
        var copy = self
        copy.threshold = self.threshold.clamped(to: self.metric.thresholdRange)
        if !self.metric.supportsDirection {
            copy.direction = .used
        }
        return copy
    }
}

struct MenuBarConditionalClause: Codable, Hashable, Sendable {
    /// nil for the first clause; ignored-on-eval if set on the first.
    var combinator: MenuBarConditionalCombinator?
    var predicate: MenuBarConditionalPredicate
}

struct MenuBarLayoutConditional: Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var clauses: [MenuBarConditionalClause] // 1...4 after normalization
    var thenToken: MenuBarLayoutToken
    var elseToken: MenuBarLayoutToken

    init(
        id: UUID = UUID(),
        name: String = "",
        clauses: [MenuBarConditionalClause],
        thenToken: MenuBarLayoutToken,
        elseToken: MenuBarLayoutToken)
    {
        self.id = id
        self.name = name
        self.clauses = clauses
        self.thenToken = thenToken
        self.elseToken = elseToken
        self.normalize()
    }

    private mutating func normalize() {
        var normalized = self.clauses.prefix(4).map { clause in
            var clause = clause
            clause.predicate = clause.predicate.normalized()
            return clause
        }
        if normalized.isEmpty {
            normalized = [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(metric: .session, comparison: .greaterThan, threshold: 0))]
        }
        normalized[0].combinator = nil
        self.clauses = Array(normalized)
    }

    /// Custom Codable so older persisted conditionals without `name` or `id` still decode.
    private enum CodingKeys: String, CodingKey {
        case id, name, clauses, thenToken, elseToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.clauses = try container.decode([MenuBarConditionalClause].self, forKey: .clauses)
        self.thenToken = try container.decode(MenuBarLayoutToken.self, forKey: .thenToken)
        self.elseToken = try container.decode(MenuBarLayoutToken.self, forKey: .elseToken)
        self.normalize()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.clauses, forKey: .clauses)
        try container.encode(self.thenToken, forKey: .thenToken)
        try container.encode(self.elseToken, forKey: .elseToken)
    }

    static func makeDefault() -> MenuBarLayoutConditional {
        MenuBarLayoutConditional(
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(metric: .session, comparison: .greaterThan, threshold: 0))],
            thenToken: .percent(window: .session),
            elseToken: .hidden)
    }

    /// Conditionals seeded into the library on a fresh install so the palette ships with useful,
    /// editable starting points instead of an empty list.
    ///
    /// Identities are fixed rather than generated: a layout that places a shipped conditional keeps
    /// resolving across launches, and once the user edits or clears the library the stored array wins,
    /// so a deleted entry is never reseeded.
    ///
    /// Percent thresholds compare the window's **used** percentage and countdown thresholds compare hours
    /// until the window resets, both matching `evaluatesTrue`.
    static func shippedLibrary() -> [MenuBarLayoutConditional] {
        [
            MenuBarLayoutConditional(
                id: self.fixedID("B715B1D1-8C1D-4E99-8050-2B5A4EF4B684"),
                name: L("menu_bar_layout_conditional_default_session_busy"),
                clauses: [self.clause(.session, .greaterThan, 50)],
                thenToken: .percent(window: .session),
                elseToken: .hidden),
            MenuBarLayoutConditional(
                id: self.fixedID("A1C3C131-1BB8-4248-A482-FAF3E403E6E1"),
                name: L("menu_bar_layout_conditional_default_weekly_high"),
                clauses: [self.clause(.weekly, .greaterThanOrEqual, 90)],
                thenToken: .percent(window: .weekly),
                elseToken: .hidden),
            MenuBarLayoutConditional(
                id: self.fixedID("DBF99E1D-D5ED-4D55-AD24-A4171479DA3A"),
                name: L("menu_bar_layout_conditional_default_session_spent"),
                clauses: [self.clause(.session, .greaterThanOrEqual, 95)],
                thenToken: .resetCountdown,
                elseToken: .percent(window: .session)),
            MenuBarLayoutConditional(
                id: self.fixedID("CB1EBADE-B813-4B70-A32D-0FC742DC97A6"),
                name: L("menu_bar_layout_conditional_default_either_high"),
                clauses: [
                    self.clause(.session, .greaterThan, 80),
                    self.clause(.weekly, .greaterThan, 80, combinator: .or),
                ],
                thenToken: .resetCountdown,
                elseToken: .hidden),
            MenuBarLayoutConditional(
                id: self.fixedID("4A4E53F8-CABC-4413-B7AA-6C6452A69FEC"),
                name: L("menu_bar_layout_conditional_default_scoped_weekly"),
                clauses: [self.clause(.scopedWeekly, .greaterThan, 60)],
                thenToken: .percent(window: .scopedWeekly),
                elseToken: .hidden),
            MenuBarLayoutConditional(
                id: self.fixedID("98257E78-8E87-4BE4-A917-73F98310143C"),
                // Composed from the two palette token labels it switches between, so the chip always
                // reads in the same words as the tokens themselves in every language.
                name: "\(L("menu_bar_layout_token_auto")) / \(L("menu_bar_layout_token_resets_in"))",
                clauses: [self.clause(.automatic, .greaterThanOrEqual, 1, direction: .remaining)],
                thenToken: .percent(window: .automatic),
                elseToken: .resetCountdown),
        ]
    }

    private static func clause(
        _ metric: MenuBarConditionalMetric,
        _ comparison: MenuBarConditionalComparison,
        _ threshold: Double,
        direction: MenuBarConditionalDirection = .used,
        combinator: MenuBarConditionalCombinator? = nil)
        -> MenuBarConditionalClause
    {
        MenuBarConditionalClause(
            combinator: combinator,
            predicate: MenuBarConditionalPredicate(
                metric: metric,
                direction: direction,
                comparison: comparison,
                threshold: threshold))
    }

    /// The shipped identities are compile-time constants, so a malformed one is a programmer error
    /// rather than something to paper over with a fresh identity that would dangle placed references.
    private static func fixedID(_ string: String) -> UUID {
        guard let id = UUID(uuidString: string) else {
            preconditionFailure("Shipped conditional identity must be a valid UUID: \(string)")
        }
        return id
    }
}

/// Array element wrapper that tolerates one undecodable conditional instead of failing the whole
/// library. A conditional using a metric this build does not recognize — a downgrade reading a library
/// written by a newer release — must not take every other entry down with it; layouts referencing a
/// dropped entry already render the dangling-conditional placeholder.
struct LenientMenuBarLayoutConditional: Decodable {
    let value: MenuBarLayoutConditional?

    init(from decoder: Decoder) throws {
        self.value = try? MenuBarLayoutConditional(from: decoder)
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
    /// Renders nothing; used as a conditional branch value to hide output for the other case.
    case hidden
    /// References a library conditional by UUID. The conditional's content (clauses, branches) lives in
    /// the conditionals library; the layout stores only its identity.
    case conditional(id: UUID)

    var selectedLane: MenuBarLayoutLane? {
        if case let .lanePercent(lane) = self { return lane }
        return nil
    }

    /// Tokens added after 0.53.x that an older decoder has no case for at all. `legacyCompatible`
    /// cannot map them onto an existing case without inventing content, so the layout projection
    /// drops them instead: an older release then decodes the rest of the layout rather than
    /// failing the whole blob and losing the user's arrangement.
    var hasLegacyRepresentation: Bool {
        switch self {
        case .conditional, .hidden: false
        default: true
        }
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

    /// Numeric USD amounts behind OpenRouter's "Credits" detail rows. The plugin formats both rows as
    /// `$` + `toFixed(2)` (`Sources/CodexBarCore/Resources/Plugins/openrouter.js`), so the amounts are
    /// USD with no grouping separators; the plugin never populates `providerCost`, so there is nothing
    /// structured to read instead.
    static func balanceAmountsUSD(
        provider: UsageProvider,
        snapshot: UsageSnapshot?)
        -> (remaining: Double?, used: Double?)
    {
        // Provider-specific by design: only OpenRouter reports credit amounts in its "Credits" detail rows.
        guard provider == .openrouter else { return (nil, nil) }
        return (
            self.amount(snapshot?.detailRow(label: "Remaining")?.value),
            self.amount(snapshot?.detailRow(label: "Used")?.value))
    }

    private static func amount(_ text: String?) -> Double? {
        guard let text else { return nil }
        return Double(text.filter { $0.isNumber || $0 == "." || $0 == "-" })
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

    /// Older-readable projection of this layout. Tokens an older decoder cannot represent are
    /// dropped rather than mapped; a line left empty by that filtering is dropped too, and a layout
    /// with nothing left falls back to `defaultLayout` via `MenuBarLayout(lines:)` normalization.
    func legacyCompatible(for provider: UsageProvider? = nil) -> MenuBarLayout {
        let projected = self.lines.map { line in
            line
                .filter(\.hasLegacyRepresentation)
                .map { $0.legacyCompatible(for: provider) }
        }
        // Keep a trailing empty line only when the layout was already stacked with an empty line,
        // so an older release does not inherit a blank stacked row created purely by filtering.
        let compacted = projected.enumerated().filter { index, line in
            !line.isEmpty || self.lines[index].isEmpty
        }.map(\.element)
        return MenuBarLayout(lines: compacted)
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

    /// Pre-V2 installs only have the legacy keys. Materialize V2 plus an older-readable projection
    /// at load so an immediate downgrade does not need an editor write first. Leave both keys
    /// untouched when they disagree: that is an older-release edit.
    static func needsStartupDualWrite(current: MenuBarLayout?, legacy: MenuBarLayout?) -> Bool {
        switch (current, legacy) {
        case (nil, .some): true
        case (.some, nil): true
        default: false
        }
    }

    static func needsStartupDualWrite(
        current: [String: MenuBarLayout]?,
        legacy: [String: MenuBarLayout]?)
        -> Bool
    {
        switch (current, legacy) {
        case (nil, let legacy?): !legacy.isEmpty
        case (let current?, nil): !current.isEmpty
        default: false
        }
    }

    static func encoded(
        _ layout: MenuBarLayout,
        provider: UsageProvider? = nil)
        throws -> (current: Data, legacy: Data)
    {
        let encoder = JSONEncoder()
        let current = try encoder.encode(layout)
        let legacy = try encoder.encode(layout.legacyCompatible(for: provider))
        return (current, legacy)
    }

    static func encodedOverrides(_ overrides: [String: MenuBarLayout]) throws -> (current: Data, legacy: Data) {
        let encoder = JSONEncoder()
        let legacyOverrides = Dictionary(uniqueKeysWithValues: overrides.map { key, layout in
            (key, layout.legacyCompatible(for: UsageProvider(rawValue: key)))
        })
        return try (encoder.encode(overrides), encoder.encode(legacyOverrides))
    }

    static func loadLayout(
        current: MenuBarLayout?,
        legacy: MenuBarLayout?,
        into userDefaults: UserDefaults)
        -> MenuBarLayout?
    {
        let preferred = self.preferredLayout(current: current, legacy: legacy)
        if let preferred,
           self.needsStartupDualWrite(current: current, legacy: legacy),
           let blobs = try? self.encoded(preferred)
        {
            userDefaults.set(blobs.current, forKey: MenuBarLayoutUserDefaultsKey.layoutCurrent)
            userDefaults.set(blobs.legacy, forKey: MenuBarLayoutUserDefaultsKey.layout)
        }
        return preferred
    }

    static func loadOverrides(
        current: [String: MenuBarLayout]?,
        legacy: [String: MenuBarLayout]?,
        into userDefaults: UserDefaults)
        -> [String: MenuBarLayout]
    {
        let preferred = self.preferredOverrides(current: current, legacy: legacy)
        if self.needsStartupDualWrite(current: current, legacy: legacy),
           let blobs = try? self.encodedOverrides(preferred)
        {
            userDefaults.set(blobs.current, forKey: MenuBarLayoutUserDefaultsKey.overridesCurrent)
            userDefaults.set(blobs.legacy, forKey: MenuBarLayoutUserDefaultsKey.overrides)
        }
        return preferred
    }
}

extension MenuBarLayout {
    /// Every token in the layout plus all tokens reachable through conditional branches (depth-capped).
    func flattenedTokens(conditionals: [MenuBarLayoutConditional]) -> [MenuBarLayoutToken] {
        let byID = Dictionary(conditionals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var tokens: [MenuBarLayoutToken] = []
        for token in self.lines.joined() {
            token.appendFlattened(into: &tokens, conditionals: byID, depth: 0)
        }
        return tokens
    }

    /// Every predicate reachable from the conditionals this layout places, including nested branches
    /// (depth-capped by `flattenedTokens`). Data-dependency gates use this to see what the conditionals
    /// read: a predicate on cost or time to reset has no matching display token to detect.
    func referencedConditionalPredicates(
        conditionals: [MenuBarLayoutConditional])
        -> [MenuBarConditionalPredicate]
    {
        let byID = Dictionary(conditionals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return self.flattenedTokens(conditionals: conditionals)
            .flatMap { token -> [MenuBarConditionalPredicate] in
                guard case let .conditional(id) = token, let conditional = byID[id] else { return [] }
                return conditional.clauses.map(\.predicate)
            }
    }

    /// Returns a layout with every `.conditional(id:)` token matching `id` removed from both lines,
    /// or nil when nothing referenced it (so callers never materialize an unchanged stored layout).
    func removingConditional(id: UUID) -> MenuBarLayout? {
        var changed = false
        let filtered = self.lines.map { line in
            line.filter { token in
                if case let .conditional(tokenID) = token, tokenID == id {
                    changed = true
                    return false
                }
                return true
            }
        }
        guard changed else { return nil }
        return MenuBarLayout(lines: filtered)
    }
}

extension MenuBarLayoutToken {
    static let maxConditionalDepth = 8

    func appendFlattened(
        into tokens: inout [MenuBarLayoutToken],
        conditionals: [UUID: MenuBarLayoutConditional],
        depth: Int)
    {
        if self == .hidden { return }
        tokens.append(self)
        guard depth < Self.maxConditionalDepth,
              case let .conditional(id) = self,
              let conditional = conditionals[id]
        else { return }
        conditional.thenToken.appendFlattened(into: &tokens, conditionals: conditionals, depth: depth + 1)
        conditional.elseToken.appendFlattened(into: &tokens, conditionals: conditionals, depth: depth + 1)
    }
}
