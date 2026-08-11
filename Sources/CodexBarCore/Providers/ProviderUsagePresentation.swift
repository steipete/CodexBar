import Foundation

public struct ProviderRateWindowLabels: Sendable, Equatable {
    public let primary: String
    public let secondary: String
    public let tertiary: String
    public let showsTertiary: Bool

    public init(primary: String, secondary: String, tertiary: String, showsTertiary: Bool) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.showsTertiary = showsTertiary
    }
}

public struct ProviderIdentityPresentation: Sendable, Equatable {
    public struct Detail: Sendable, Equatable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public let badge: String?
    public let plan: String?
    public let details: [Detail]

    public init(badge: String?, plan: String?, details: [Detail] = []) {
        self.badge = badge
        self.plan = plan
        self.details = details
    }
}

public struct ProviderPlanRowPresentation: Sendable, Equatable {
    public let label: String
    public let balancePrefixedLabel: String
    public let stripsBalancePrefix: Bool

    public init(
        label: String = "Plan",
        balancePrefixedLabel: String = "Balance",
        stripsBalancePrefix: Bool = false)
    {
        self.label = label
        self.balancePrefixedLabel = balancePrefixedLabel
        self.stripsBalancePrefix = stripsBalancePrefix
    }
}

public enum ProviderCostMenuCardStyle: Sendable, Equatable {
    case generic
    case hidden
    case extraUsageBalance
    case zenBalance
    case pointsBalance
    case prepaidCredits
    case payAsYouGoBalance
    case claude
    case apiSpend
    case clawRouter
}

public struct ProviderCostPresentation: Sendable, Equatable {
    public struct Balance: Sendable, Equatable {
        public let label: String
        public let amount: Double
        public let currencyCode: String

        public init(label: String, amount: Double, currencyCode: String) {
            self.label = label
            self.amount = amount
            self.currencyCode = currencyCode
        }
    }

    public let showsGenericFallback: Bool
    public let balances: [Balance]
    public let menuCardStyle: ProviderCostMenuCardStyle

    public init(
        showsGenericFallback: Bool = true,
        balances: [Balance] = [],
        menuCardStyle: ProviderCostMenuCardStyle = .generic)
    {
        self.showsGenericFallback = showsGenericFallback
        self.balances = balances
        self.menuCardStyle = menuCardStyle
    }
}

public struct ProviderOptionalDetailsPresentation: Sendable, Equatable {
    public let hidesAllWithoutOptionalUsage: Bool
    public let hiddenTitlesWithoutOptionalUsage: Set<String>

    public init(
        hidesAllWithoutOptionalUsage: Bool = false,
        hiddenTitlesWithoutOptionalUsage: Set<String> = [])
    {
        self.hidesAllWithoutOptionalUsage = hidesAllWithoutOptionalUsage
        self.hiddenTitlesWithoutOptionalUsage = hiddenTitlesWithoutOptionalUsage
    }
}

public enum ProviderUsageLane: Sendable, Hashable {
    case primary
    case secondary
    case tertiary
}

public enum ProviderSemanticWindow: Sendable, Equatable {
    case session
    case weekly
}

public struct ProviderSemanticWindows: Sendable, Equatable {
    public let session: RateWindow?
    public let weekly: RateWindow?

    public init(session: RateWindow?, weekly: RateWindow?) {
        self.session = session
        self.weekly = weekly
    }
}

public struct ProviderUsageWindowPair: Sendable, Equatable {
    public let primary: RateWindow?
    public let secondary: RateWindow?

    public init(primary: RateWindow?, secondary: RateWindow?) {
        self.primary = primary
        self.secondary = secondary
    }
}

public struct ProviderIconDecorations: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let face = Self(rawValue: 1 << 0)
    public static let notches = Self(rawValue: 1 << 1)
    public static let gemini = Self(rawValue: 1 << 2)
    public static let antigravity = Self(rawValue: 1 << 3)
    public static let factory = Self(rawValue: 1 << 4)
    public static let warp = Self(rawValue: 1 << 5)
}

public struct ProviderIconWindowContext: Sendable {
    public let snapshot: UsageSnapshot
    public let secondaryOverrideWindowID: String?
    public let now: Date

    public init(snapshot: UsageSnapshot, secondaryOverrideWindowID: String?, now: Date) {
        self.snapshot = snapshot
        self.secondaryOverrideWindowID = secondaryOverrideWindowID
        self.now = now
    }
}

public struct ProviderMenuBarWindowContext: Sendable {
    public let metric: ProviderMenuBarMetric
    public let snapshot: UsageSnapshot
    public let supportsAverage: Bool
    public let prioritizesExhaustedQuotas: Bool
    public let now: Date

    public init(
        metric: ProviderMenuBarMetric,
        snapshot: UsageSnapshot,
        supportsAverage: Bool,
        prioritizesExhaustedQuotas: Bool,
        now: Date)
    {
        self.metric = metric
        self.snapshot = snapshot
        self.supportsAverage = supportsAverage
        self.prioritizesExhaustedQuotas = prioritizesExhaustedQuotas
        self.now = now
    }
}

public enum ProviderMenuBarWindowResolution: Sendable {
    case unhandled
    case resolved(RateWindow?)
}

public enum ProviderPlanUtilizationSeries: Sendable, Hashable {
    case session
    case weekly
    case tertiary
    case monthly
}

public enum ProviderWidgetFamily: Sendable {
    case small
    case medium
}

public struct ProviderUsageNotesContext: Sendable {
    public let snapshot: UsageSnapshot?
    public let isRefreshing: Bool
    public let tokenCostInlineDashboardEnabled: Bool
    public let showOptionalUsage: Bool

    public init(
        snapshot: UsageSnapshot?,
        isRefreshing: Bool,
        tokenCostInlineDashboardEnabled: Bool,
        showOptionalUsage: Bool)
    {
        self.snapshot = snapshot
        self.isRefreshing = isRefreshing
        self.tokenCostInlineDashboardEnabled = tokenCostInlineDashboardEnabled
        self.showOptionalUsage = showOptionalUsage
    }
}

public enum ProviderUsageNotesResolution: Sendable {
    case unhandled
    case openAIAPI(OpenAIAPIUsageSnapshot)
    case localized([String])
}

public enum ProviderCreditsVisibility: Sendable, Equatable {
    case standard
    case requiresValueOrError
    case hiddenWhenUsageSnapshotPresent
    case hidden
}

public struct ProviderCostVisibilityContext: Sendable {
    public let snapshot: UsageSnapshot?
    public let showOptionalUsage: Bool

    public init(snapshot: UsageSnapshot?, showOptionalUsage: Bool) {
        self.snapshot = snapshot
        self.showOptionalUsage = showOptionalUsage
    }
}

public enum ProviderPrimaryDescriptionPlacement: Sendable {
    case standard
    case reset
    case detail
    case detailLeft
    case detailBySecondaryPresence
}

public enum ProviderPrimaryDetailKind: Sendable {
    case none
    case poeBalance
    case kiroCredits
    case requestQuota
}

public struct ProviderMenuCardPresentation: Sendable {
    public typealias UsageNotesResolver = @Sendable (ProviderUsageNotesContext) -> ProviderUsageNotesResolution
    public typealias CostVisibilityResolver = @Sendable (ProviderCostVisibilityContext) -> Bool
    public typealias SnapshotPredicate = @Sendable (_ snapshot: UsageSnapshot?) -> Bool
    public typealias PrimaryCostHistoryResolver = @Sendable (
        _ snapshot: UsageSnapshot?,
        _ tokenSnapshot: CostUsageTokenSnapshot?) -> CostUsageTokenSnapshot?

    private let usageNotesResolver: UsageNotesResolver
    private let costVisibilityResolver: CostVisibilityResolver
    private let movePrimaryDetailToStatus: SnapshotPredicate
    private let primaryCostHistoryResolver: PrimaryCostHistoryResolver
    public let creditsVisibility: ProviderCreditsVisibility
    public let showsCreditsSection: Bool
    public let usesProviderCostHistoryAsPrimaryDashboard: Bool
    public let supportsInlineTokenCostDashboard: Bool
    public let primaryDescriptionPlacement: ProviderPrimaryDescriptionPlacement
    public let showsPrimaryBalanceDescription: Bool
    public let hidesPrimaryResetWithoutDate: Bool
    public let hidesPrimaryResetWithoutSecondary: Bool
    public let clearsPrimaryReset: Bool
    public let primaryDetailKind: ProviderPrimaryDetailKind
    public let usesAbacusPace: Bool
    public let usesSyntheticRollingRegen: Bool
    public let usesRawPrimaryResetDescription: Bool
    public let resetWindowUsesWeeklyPace: Bool

    public init(
        usageNotesResolver: @escaping UsageNotesResolver = { _ in .unhandled },
        creditsVisibility: ProviderCreditsVisibility = .standard,
        showsCreditsSection: Bool = true,
        costVisibilityResolver: @escaping CostVisibilityResolver = { _ in true },
        usesProviderCostHistoryAsPrimaryDashboard: Bool = false,
        primaryCostHistoryResolver: @escaping PrimaryCostHistoryResolver = { _, tokenSnapshot in tokenSnapshot },
        supportsInlineTokenCostDashboard: Bool = false,
        primaryDescriptionPlacement: ProviderPrimaryDescriptionPlacement = .standard,
        showsPrimaryBalanceDescription: Bool = false,
        hidesPrimaryResetWithoutDate: Bool = false,
        hidesPrimaryResetWithoutSecondary: Bool = false,
        clearsPrimaryReset: Bool = false,
        movePrimaryDetailToStatus: @escaping SnapshotPredicate = { _ in false },
        primaryDetailKind: ProviderPrimaryDetailKind = .none,
        usesAbacusPace: Bool = false,
        usesSyntheticRollingRegen: Bool = false,
        usesRawPrimaryResetDescription: Bool = false,
        resetWindowUsesWeeklyPace: Bool = false)
    {
        self.usageNotesResolver = usageNotesResolver
        self.creditsVisibility = creditsVisibility
        self.showsCreditsSection = showsCreditsSection
        self.costVisibilityResolver = costVisibilityResolver
        self.usesProviderCostHistoryAsPrimaryDashboard = usesProviderCostHistoryAsPrimaryDashboard
        self.primaryCostHistoryResolver = primaryCostHistoryResolver
        self.supportsInlineTokenCostDashboard = supportsInlineTokenCostDashboard
        self.primaryDescriptionPlacement = primaryDescriptionPlacement
        self.showsPrimaryBalanceDescription = showsPrimaryBalanceDescription
        self.hidesPrimaryResetWithoutDate = hidesPrimaryResetWithoutDate
        self.hidesPrimaryResetWithoutSecondary = hidesPrimaryResetWithoutSecondary
        self.clearsPrimaryReset = clearsPrimaryReset
        self.movePrimaryDetailToStatus = movePrimaryDetailToStatus
        self.primaryDetailKind = primaryDetailKind
        self.usesAbacusPace = usesAbacusPace
        self.usesSyntheticRollingRegen = usesSyntheticRollingRegen
        self.usesRawPrimaryResetDescription = usesRawPrimaryResetDescription
        self.resetWindowUsesWeeklyPace = resetWindowUsesWeeklyPace
    }

    public func usageNotes(context: ProviderUsageNotesContext) -> ProviderUsageNotesResolution {
        self.usageNotesResolver(context)
    }

    public func showsProviderCost(context: ProviderCostVisibilityContext) -> Bool {
        self.costVisibilityResolver(context)
    }

    public func movesPrimaryDetailToStatus(snapshot: UsageSnapshot?) -> Bool {
        self.movePrimaryDetailToStatus(snapshot)
    }

    public func primaryCostHistory(
        snapshot: UsageSnapshot?,
        tokenSnapshot: CostUsageTokenSnapshot?) -> CostUsageTokenSnapshot?
    {
        self.primaryCostHistoryResolver(snapshot, tokenSnapshot)
    }
}

public enum ProviderSecondaryDescriptionMode: Sendable, Equatable {
    case standard
    case resetOverride
    case detailWhenResetDatePresent
}

public struct ProviderMenuDescriptorPresentation: Sendable {
    public typealias SnapshotPredicate = @Sendable (_ snapshot: UsageSnapshot) -> Bool

    private let primaryDescriptionIsDetail: SnapshotPredicate
    public let duplicatesPrimaryDetailWhenResetDatePresent: Bool
    public let showsPrimaryWeeklyPace: Bool
    public let secondaryDescriptionMode: ProviderSecondaryDescriptionMode
    public let tertiaryDescriptionOverridesReset: Bool

    public init(
        primaryDescriptionIsDetail: @escaping SnapshotPredicate = { _ in false },
        duplicatesPrimaryDetailWhenResetDatePresent: Bool = false,
        showsPrimaryWeeklyPace: Bool = false,
        secondaryDescriptionMode: ProviderSecondaryDescriptionMode = .standard,
        tertiaryDescriptionOverridesReset: Bool = false)
    {
        self.primaryDescriptionIsDetail = primaryDescriptionIsDetail
        self.duplicatesPrimaryDetailWhenResetDatePresent = duplicatesPrimaryDetailWhenResetDatePresent
        self.showsPrimaryWeeklyPace = showsPrimaryWeeklyPace
        self.secondaryDescriptionMode = secondaryDescriptionMode
        self.tertiaryDescriptionOverridesReset = tertiaryDescriptionOverridesReset
    }

    public func usesPrimaryDescriptionAsDetail(snapshot: UsageSnapshot) -> Bool {
        self.primaryDescriptionIsDetail(snapshot)
    }
}

public struct ProviderUsagePresentation: Sendable {
    public typealias RateWindowLabeler = @Sendable (
        _ metadata: ProviderMetadata,
        _ snapshot: UsageSnapshot,
        _ now: Date) -> ProviderRateWindowLabels
    public typealias IdentityPresenter = @Sendable (
        _ provider: UsageProvider,
        _ snapshot: UsageSnapshot) -> ProviderIdentityPresentation
    public typealias CostPresenter = @Sendable (_ snapshot: UsageSnapshot) -> ProviderCostPresentation
    public typealias ExtraRateWindowSelector = @Sendable (_ snapshot: UsageSnapshot) -> [NamedRateWindow]
    public typealias CreditResolver = @Sendable (_ credits: CreditsSnapshot) -> Double?
    public typealias IconWindowResolver = @Sendable (ProviderIconWindowContext) -> ProviderUsageWindowPair
    public typealias SemanticWindowResolver = @Sendable (_ snapshot: UsageSnapshot) -> ProviderSemanticWindows
    public typealias MenuBarWindowResolver = @Sendable (
        ProviderMenuBarWindowContext) -> ProviderMenuBarWindowResolution
    public typealias PlanUtilizationSeriesResolver = @Sendable (
        _ snapshot: UsageSnapshot) -> Set<ProviderPlanUtilizationSeries>?
    public typealias PlanUtilizationSeriesNormalizer = @Sendable (
        _ series: ProviderPlanUtilizationSeries,
        _ windowMinutes: Int) -> ProviderPlanUtilizationSeries
    public typealias WidgetRowLimitResolver = @Sendable (
        _ rows: [WidgetSnapshot.WidgetUsageRowSnapshot]?,
        _ family: ProviderWidgetFamily) -> Int?

    private let rateWindowLabeler: RateWindowLabeler?
    private let identityPresenter: IdentityPresenter?
    private let costPresenter: CostPresenter
    private let extraRateWindowSelector: ExtraRateWindowSelector
    private let creditResolver: CreditResolver?
    private let iconWindowResolver: IconWindowResolver
    private let semanticWindowResolver: SemanticWindowResolver
    private let menuBarWindowResolver: MenuBarWindowResolver
    private let planUtilizationSeriesResolver: PlanUtilizationSeriesResolver
    private let planUtilizationSeriesNormalizer: PlanUtilizationSeriesNormalizer
    private let widgetRowLimitResolver: WidgetRowLimitResolver
    public let iconDecorations: ProviderIconDecorations
    public let treatsExhaustedSecondaryIconWindowAsMissing: Bool
    public let primarySemanticWindow: ProviderSemanticWindow
    public let secondarySemanticWindow: ProviderSemanticWindow
    public let menuBarLayoutSecondaryLabel: String?
    public let requestedMenuBarLaneOrders: [ProviderMenuBarMetric: [ProviderUsageLane]]
    public let automaticSelectionPrioritizesExhaustedWindow: Bool
    public let secondaryGloballyCapsPrimary: Bool
    /// Longer quota lanes that must have room before the primary session lane is usable.
    /// Kept separate from widget policy until those surfaces adopt the same multi-lane projection.
    public let primaryBindingQuotaLanes: Set<ProviderUsageLane>
    public let menuCard: ProviderMenuCardPresentation
    public let menu: ProviderMenuDescriptorPresentation
    public let planRow: ProviderPlanRowPresentation
    public let optionalDetails: ProviderOptionalDetailsPresentation

    public init(
        rateWindowLabeler: RateWindowLabeler? = nil,
        identityPresenter: IdentityPresenter? = nil,
        costPresenter: @escaping CostPresenter = { _ in ProviderCostPresentation() },
        extraRateWindowSelector: @escaping ExtraRateWindowSelector = { _ in [] },
        creditResolver: CreditResolver? = nil,
        iconWindowResolver: @escaping IconWindowResolver = { context in
            ProviderUsageWindowPair(primary: context.snapshot.primary, secondary: context.snapshot.secondary)
        },
        iconDecorations: ProviderIconDecorations = [],
        treatsExhaustedSecondaryIconWindowAsMissing: Bool = false,
        semanticWindowResolver: @escaping SemanticWindowResolver = Self.standardSemanticWindows,
        primarySemanticWindow: ProviderSemanticWindow = .session,
        secondarySemanticWindow: ProviderSemanticWindow = .weekly,
        menuBarLayoutSecondaryLabel: String? = nil,
        requestedMenuBarLaneOrders: [ProviderMenuBarMetric: [ProviderUsageLane]] = [:],
        automaticSelectionPrioritizesExhaustedWindow: Bool = true,
        menuBarWindowResolver: @escaping MenuBarWindowResolver = { _ in .unhandled },
        planUtilizationSeriesResolver: @escaping PlanUtilizationSeriesResolver = Self.standardPlanUtilizationSeries,
        planUtilizationSeriesNormalizer: @escaping PlanUtilizationSeriesNormalizer = { series, _ in series },
        widgetRowLimitResolver: @escaping WidgetRowLimitResolver = { _, _ in nil },
        secondaryGloballyCapsPrimary: Bool = false,
        primaryBindingQuotaLanes: Set<ProviderUsageLane> = [],
        menuCard: ProviderMenuCardPresentation = ProviderMenuCardPresentation(),
        menu: ProviderMenuDescriptorPresentation = ProviderMenuDescriptorPresentation(),
        planRow: ProviderPlanRowPresentation = ProviderPlanRowPresentation(),
        optionalDetails: ProviderOptionalDetailsPresentation = ProviderOptionalDetailsPresentation())
    {
        self.rateWindowLabeler = rateWindowLabeler
        self.identityPresenter = identityPresenter
        self.costPresenter = costPresenter
        self.extraRateWindowSelector = extraRateWindowSelector
        self.creditResolver = creditResolver
        self.iconWindowResolver = iconWindowResolver
        self.iconDecorations = iconDecorations
        self.treatsExhaustedSecondaryIconWindowAsMissing = treatsExhaustedSecondaryIconWindowAsMissing
        self.semanticWindowResolver = semanticWindowResolver
        self.primarySemanticWindow = primarySemanticWindow
        self.secondarySemanticWindow = secondarySemanticWindow
        self.menuBarLayoutSecondaryLabel = menuBarLayoutSecondaryLabel
        self.requestedMenuBarLaneOrders = requestedMenuBarLaneOrders
        self.automaticSelectionPrioritizesExhaustedWindow = automaticSelectionPrioritizesExhaustedWindow
        self.menuBarWindowResolver = menuBarWindowResolver
        self.planUtilizationSeriesResolver = planUtilizationSeriesResolver
        self.planUtilizationSeriesNormalizer = planUtilizationSeriesNormalizer
        self.widgetRowLimitResolver = widgetRowLimitResolver
        self.secondaryGloballyCapsPrimary = secondaryGloballyCapsPrimary
        self.primaryBindingQuotaLanes = primaryBindingQuotaLanes
        self.menuCard = menuCard
        self.menu = menu
        self.planRow = planRow
        self.optionalDetails = optionalDetails
    }

    public func rateWindowLabels(
        metadata: ProviderMetadata,
        snapshot: UsageSnapshot,
        now: Date = .now) -> ProviderRateWindowLabels
    {
        self.rateWindowLabeler?(metadata, snapshot, now) ?? ProviderRateWindowLabels(
            primary: metadata.sessionLabel,
            secondary: metadata.weeklyLabel,
            tertiary: metadata.opusLabel ?? "Sonnet",
            showsTertiary: metadata.supportsOpus)
    }

    public func identity(provider: UsageProvider, snapshot: UsageSnapshot) -> ProviderIdentityPresentation {
        if let identityPresenter {
            return identityPresenter(provider, snapshot)
        }
        guard let plan = snapshot.loginMethod(for: provider), !plan.isEmpty else {
            return ProviderIdentityPresentation(badge: nil, plan: nil)
        }
        let display = plan.capitalized
        return ProviderIdentityPresentation(badge: display, plan: display)
    }

    public func cost(snapshot: UsageSnapshot) -> ProviderCostPresentation {
        self.costPresenter(snapshot)
    }

    public func extraRateWindows(snapshot: UsageSnapshot) -> [NamedRateWindow] {
        self.extraRateWindowSelector(snapshot)
    }

    public func creditRemaining(_ credits: CreditsSnapshot) -> Double? {
        self.creditResolver?(credits)
    }

    public func iconWindows(context: ProviderIconWindowContext) -> ProviderUsageWindowPair {
        self.iconWindowResolver(context)
    }

    public func semanticWindows(snapshot: UsageSnapshot) -> ProviderSemanticWindows {
        self.semanticWindowResolver(snapshot)
    }

    public func requestedMenuBarLaneOrder(for metric: ProviderMenuBarMetric) -> [ProviderUsageLane] {
        if let order = self.requestedMenuBarLaneOrders[metric] {
            return order
        }
        return switch metric {
        case .primary: [.primary, .secondary]
        case .secondary: [.secondary, .primary]
        case .tertiary: [.primary, .secondary]
        default: []
        }
    }

    public func menuBarWindow(context: ProviderMenuBarWindowContext) -> ProviderMenuBarWindowResolution {
        self.menuBarWindowResolver(context)
    }

    public func planUtilizationSeries(snapshot: UsageSnapshot) -> Set<ProviderPlanUtilizationSeries>? {
        self.planUtilizationSeriesResolver(snapshot)
    }

    public func normalizePlanUtilizationSeries(
        _ series: ProviderPlanUtilizationSeries,
        windowMinutes: Int) -> ProviderPlanUtilizationSeries
    {
        self.planUtilizationSeriesNormalizer(series, windowMinutes)
    }

    public func widgetRowLimit(
        rows: [WidgetSnapshot.WidgetUsageRowSnapshot]?,
        family: ProviderWidgetFamily) -> Int?
    {
        self.widgetRowLimitResolver(rows, family)
    }

    public static func window(in snapshot: UsageSnapshot, following lanes: [ProviderUsageLane]) -> RateWindow? {
        for lane in lanes {
            let window = switch lane {
            case .primary: snapshot.primary
            case .secondary: snapshot.secondary
            case .tertiary: snapshot.tertiary
            }
            if let window {
                return window
            }
        }
        return nil
    }

    public static func mostConstrained(_ windows: RateWindow?...) -> RateWindow? {
        windows.compactMap(\.self).max(by: { $0.usedPercent < $1.usedPercent })
    }

    public static func exhausted(_ windows: RateWindow?...) -> RateWindow? {
        windows.compactMap(\.self).first(where: { $0.remainingPercent <= 0 })
    }

    public static func standardSemanticWindows(snapshot: UsageSnapshot) -> ProviderSemanticWindows {
        let candidates = [snapshot.primary, snapshot.secondary, snapshot.tertiary]
            + (snapshot.extraRateWindows ?? []).map(\.window)
        let usable = candidates.compactMap { window -> RateWindow? in
            guard let window, !window.isSyntheticPlaceholder else { return nil }
            return window
        }
        return ProviderSemanticWindows(
            session: usable.first { window in
                guard let minutes = window.windowMinutes else { return false }
                return (60...(12 * 60)).contains(minutes)
            },
            weekly: usable.first { $0.windowMinutes == 7 * 24 * 60 })
    }

    public static func standardPlanUtilizationSeries(
        snapshot: UsageSnapshot) -> Set<ProviderPlanUtilizationSeries>?
    {
        let windows = [snapshot.primary, snapshot.secondary, snapshot.tertiary].compactMap(\.self)
            + (snapshot.extraRateWindows?.filter(\.usageKnown).map(\.window) ?? [])
        guard windows.contains(where: { $0.windowMinutes == 7 * 24 * 60 }) else { return nil }
        return [.weekly]
    }
}
