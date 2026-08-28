import Foundation

public enum ProviderTokenCostHint: Sendable, Equatable {
    case localized(String)
    case estimate
    case literal(String)
}

public enum ProviderTokenCostHistoryTitleStyle: Sendable, Equatable {
    case standard
    case compact
}

public enum ProviderTokenCostPrimaryValue: Sendable, Equatable {
    case session
    case latestDaily
}

public enum ProviderTokenCostHintPlacement: Sendable, Equatable {
    case beforeRequestHistory
    case afterRequestHistory
    case hidden
}

public struct ProviderTokenCostConfig: Sendable {
    public let supportsTokenCost: Bool
    public let noDataMessage: @Sendable () -> String
    public let menuHintLines: [ProviderTokenCostHint]
    public let supportsTokenSnapshot: Bool
    public let settingsStatusOrder: Int?
    public let showsHintInProviderDetails: Bool
    public let showsCostMenuSection: Bool
    public let estimateDisclaimer: String
    public let historyTitleStyle: ProviderTokenCostHistoryTitleStyle
    public let primaryValue: ProviderTokenCostPrimaryValue
    public let showsRequestHistory: Bool
    public let hintPlacement: ProviderTokenCostHintPlacement
    public let chartEstimateDisclaimer: ProviderTokenCostHint?

    public init(
        supportsTokenCost: Bool,
        noDataMessage: @escaping @Sendable () -> String,
        menuHintLines: [ProviderTokenCostHint] = [],
        supportsTokenSnapshot: Bool = false,
        settingsStatusOrder: Int? = nil,
        showsHintInProviderDetails: Bool = false,
        showsCostMenuSection: Bool = true,
        estimateDisclaimer: String = "Estimated from local logs · may differ from your bill",
        historyTitleStyle: ProviderTokenCostHistoryTitleStyle = .standard,
        primaryValue: ProviderTokenCostPrimaryValue = .session,
        showsRequestHistory: Bool = true,
        hintPlacement: ProviderTokenCostHintPlacement = .afterRequestHistory,
        chartEstimateDisclaimer: ProviderTokenCostHint? = nil)
    {
        self.supportsTokenCost = supportsTokenCost
        self.noDataMessage = noDataMessage
        self.menuHintLines = menuHintLines
        self.supportsTokenSnapshot = supportsTokenSnapshot
        self.settingsStatusOrder = settingsStatusOrder
        self.showsHintInProviderDetails = showsHintInProviderDetails
        self.showsCostMenuSection = showsCostMenuSection
        self.estimateDisclaimer = estimateDisclaimer
        self.historyTitleStyle = historyTitleStyle
        self.primaryValue = primaryValue
        self.showsRequestHistory = showsRequestHistory
        self.hintPlacement = hintPlacement
        self.chartEstimateDisclaimer = chartEstimateDisclaimer
    }
}

public struct ProviderHistoryCapability: Sendable, Equatable {
    public static let optIn = ProviderHistoryCapability(alwaysTracksPlanUtilization: false)
    public static let alwaysTracked = ProviderHistoryCapability(alwaysTracksPlanUtilization: true)

    public let alwaysTracksPlanUtilization: Bool

    public init(alwaysTracksPlanUtilization: Bool) {
        self.alwaysTracksPlanUtilization = alwaysTracksPlanUtilization
    }
}

public struct ProviderConfigCapabilities: Sendable, Equatable {
    public let workspaceIDValidationOrder: Int?
    public let supportsEnterpriseHost: Bool

    public init(
        workspaceIDValidationOrder: Int? = nil,
        supportsEnterpriseHost: Bool = false)
    {
        self.workspaceIDValidationOrder = workspaceIDValidationOrder
        self.supportsEnterpriseHost = supportsEnterpriseHost
    }
}

public enum ProviderMenuBarMetric: Sendable, Hashable {
    case automatic
    case primary
    case secondary
    case primaryAndSecondary
    case tertiary
    case extraUsage
    case average
    case monthlyPlan
}

public struct ProviderMenuBarMetricCapabilities: Sendable, Equatable {
    public static let automaticOnly = Self(supported: [.automatic])
    public static let standard = Self(supported: [.automatic, .primary, .secondary])

    public let supported: Set<ProviderMenuBarMetric>
    public let tertiaryRequiresWindow: Bool

    public init(
        supported: Set<ProviderMenuBarMetric>,
        tertiaryRequiresWindow: Bool = false)
    {
        self.supported = supported
        self.tertiaryRequiresWindow = tertiaryRequiresWindow
    }

    public func supports(_ metric: ProviderMenuBarMetric) -> Bool {
        self.supported.contains(metric)
    }
}

public enum ProviderPaceWindowRule: Sendable {
    case unsupported
    case resetDatePresent
    case windowDurationPresent
    case windowDuration(minutes: Int)
    case custom(@Sendable (_ window: RateWindow, _ now: Date) -> Bool)

    public func matches(window: RateWindow, now: Date) -> Bool {
        switch self {
        case .unsupported:
            false
        case .resetDatePresent:
            window.resetsAt != nil
        case .windowDurationPresent:
            window.windowMinutes != nil
        case let .windowDuration(minutes):
            window.windowMinutes == minutes
        case let .custom(predicate):
            predicate(window, now)
        }
    }
}

public enum ProviderPaceDurationRule: Sendable {
    case unsupported
    case windowDurationMissing
    case windowDuration(minutes: Int)
    case custom(@Sendable (_ window: RateWindow) -> Bool)

    public func matches(window: RateWindow) -> Bool {
        switch self {
        case .unsupported:
            false
        case .windowDurationMissing:
            window.windowMinutes == nil
        case let .windowDuration(minutes):
            window.windowMinutes == minutes
        case let .custom(predicate):
            predicate(window)
        }
    }
}

public enum ProviderPaceKind: Sendable {
    case session
    case weekly

    public var defaultWindowMinutes: Int {
        switch self {
        case .session: 300
        case .weekly: 10080
        }
    }
}

public enum ProviderPaceSlot: Sendable {
    case primary
    case secondary
    case tertiary
}

public struct ProviderStandardPaceLane: Sendable {
    public let kind: ProviderPaceKind
    public let windowRule: ProviderPaceWindowRule

    public init(kind: ProviderPaceKind, windowRule: ProviderPaceWindowRule) {
        self.kind = kind
        self.windowRule = windowRule
    }

    public static func session(maximumMinutes: Int, requiresDuration: Bool = false) -> Self {
        Self(kind: .session, windowRule: .custom { window, _ in
            guard let minutes = window.windowMinutes else { return !requiresDuration }
            return minutes <= maximumMinutes
        })
    }

    public static var weekly: Self {
        Self(kind: .weekly, windowRule: .custom { _, _ in true })
    }

    public static var weeklyWithDuration: Self {
        Self(kind: .weekly, windowRule: .windowDurationPresent)
    }

    public static func exact(kind: ProviderPaceKind, minutes: Int) -> Self {
        Self(kind: kind, windowRule: .windowDuration(minutes: minutes))
    }
}

public struct ProviderPaceCapability: Sendable {
    public static let monthlyWindowSentinelMinutes = 30 * 24 * 60
    public static let unsupported = ProviderPaceCapability()
    public static let calendarMonthResetWindow = ProviderPaceCapability(
        resetWindowPace: .windowDuration(minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes),
        inferredMonthlyDuration: .windowDuration(minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes))

    public let resetWindowPace: ProviderPaceWindowRule
    public let inferredMonthlyDuration: ProviderPaceDurationRule
    public let primary: ProviderStandardPaceLane?
    public let secondary: ProviderStandardPaceLane?
    public let tertiary: ProviderStandardPaceLane?
    public let showsHeadroomHint: Bool
    public let sessionPaceWindowRule: ProviderPaceWindowRule

    public init(
        resetWindowPace: ProviderPaceWindowRule = .unsupported,
        inferredMonthlyDuration: ProviderPaceDurationRule = .unsupported,
        primary: ProviderStandardPaceLane? = nil,
        secondary: ProviderStandardPaceLane? = nil,
        tertiary: ProviderStandardPaceLane? = nil,
        showsHeadroomHint: Bool = false,
        sessionPaceWindowRule: ProviderPaceWindowRule = .unsupported)
    {
        self.resetWindowPace = resetWindowPace
        self.inferredMonthlyDuration = inferredMonthlyDuration
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.showsHeadroomHint = showsHeadroomHint
        self.sessionPaceWindowRule = sessionPaceWindowRule
    }

    public func supportsResetWindowPace(window: RateWindow, now: Date) -> Bool {
        self.resetWindowPace.matches(window: window, now: now)
    }

    public func usesInferredMonthlyDuration(window: RateWindow) -> Bool {
        self.inferredMonthlyDuration.matches(window: window)
    }

    public func resolvedResetWindowForPace(_ window: RateWindow) -> RateWindow {
        guard self.usesInferredMonthlyDuration(window: window),
              let resetsAt = window.resetsAt,
              let minutes = Self.inferredMonthlyWindowMinutes(endingAt: resetsAt)
        else { return window }
        return RateWindow(
            usedPercent: window.usedPercent,
            windowMinutes: minutes,
            resetsAt: window.resetsAt,
            resetDescription: window.resetDescription,
            nextRegenPercent: window.nextRegenPercent,
            isSyntheticPlaceholder: window.isSyntheticPlaceholder)
    }

    public func resolvedKind(slot: ProviderPaceSlot, window: RateWindow, now: Date) -> ProviderPaceKind? {
        if self.supportsResetWindowPace(window: window, now: now) {
            return .weekly
        }
        let lane = switch slot {
        case .primary: self.primary
        case .secondary: self.secondary
        case .tertiary: self.tertiary
        }
        guard let lane, lane.windowRule.matches(window: window, now: now) else { return nil }
        return lane.kind
    }

    public func supportsSessionPace(window: RateWindow, now: Date) -> Bool {
        self.sessionPaceWindowRule.matches(window: window, now: now)
    }

    private static func inferredMonthlyWindowMinutes(endingAt resetsAt: Date) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        guard let startsAt = calendar.date(byAdding: .month, value: -1, to: resetsAt) else { return nil }
        let minutes = resetsAt.timeIntervalSince(startsAt) / 60
        guard minutes.isFinite, minutes > 0 else { return nil }
        return Int(minutes.rounded())
    }
}

public struct ProviderDescriptor: Sendable {
    public let id: UsageProvider
    public let metadata: ProviderMetadata
    public let branding: ProviderBranding
    public let tokenCost: ProviderTokenCostConfig
    public let pace: ProviderPaceCapability
    public let history: ProviderHistoryCapability
    public let presentation: ProviderUsagePresentation
    public let settingsSection: ProviderSettingsSectionRegistration
    public let credentials: ProviderCredentialAdapter?
    public let config: ProviderConfigCapabilities
    public let menuBarMetrics: ProviderMenuBarMetricCapabilities
    public let fetchPlan: ProviderFetchPlan
    public let cli: ProviderCLIConfig
    private let configNormalizer: @Sendable (inout ProviderConfig) -> Void

    public init(
        id: UsageProvider,
        menuBarMetrics: ProviderMenuBarMetricCapabilities? = nil,
        settingsSection: ProviderSettingsSectionRegistration? = nil,
        credentials: ProviderCredentialAdapter? = nil,
        config: ProviderConfigCapabilities = ProviderConfigCapabilities(),
        metadata: ProviderMetadata,
        branding: ProviderBranding,
        tokenCost: ProviderTokenCostConfig,
        pace: ProviderPaceCapability = .unsupported,
        history: ProviderHistoryCapability = .optIn,
        presentation: ProviderUsagePresentation = ProviderUsagePresentation(),
        fetchPlan: ProviderFetchPlan,
        cli: ProviderCLIConfig,
        configNormalizer: @escaping @Sendable (inout ProviderConfig) -> Void = { _ in })
    {
        self.id = id
        self.settingsSection = settingsSection ?? .empty(for: id.instanceID)
        self.metadata = metadata
        self.branding = branding
        self.tokenCost = tokenCost
        self.pace = pace
        self.history = history
        self.presentation = presentation
        self.credentials = credentials
        self.config = config
        self.menuBarMetrics = menuBarMetrics ?? (metadata.balanceOnly ? .automaticOnly : .standard)
        self.fetchPlan = fetchPlan
        self.cli = cli
        self.configNormalizer = configNormalizer
    }

    public func fetchOutcome(context: ProviderFetchContext) async -> ProviderFetchOutcome {
        await self.fetchPlan.fetchOutcome(context: context, provider: self.id)
    }

    public func fetch(context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let outcome = await self.fetchOutcome(context: context)
        return try outcome.result.get()
    }

    public func normalizeConfig(_ config: inout ProviderConfig) {
        self.configNormalizer(&config)
    }
}

public enum ProviderDescriptorRegistry {
    private final class Store: @unchecked Sendable {
        var ordered: [ProviderDescriptor] = []
        var byID: [UsageProvider: ProviderDescriptor] = [:]
    }

    private static let lock = NSLock()
    private static let store = Store()
    private static let bootstrap: Void = {
        for descriptor in ProviderManifest.allDescriptors {
            _ = ProviderDescriptorRegistry.register(descriptor)
        }
    }()

    private static func ensureBootstrapped() {
        _ = self.bootstrap
    }

    @discardableResult
    public static func register(_ descriptor: ProviderDescriptor) -> ProviderDescriptor {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.store.byID[descriptor.id] == nil {
            self.store.ordered.append(descriptor)
        }
        self.store.byID[descriptor.id] = descriptor
        return descriptor
    }

    public static var all: [ProviderDescriptor] {
        self.ensureBootstrapped()
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.store.ordered
    }

    public static var metadata: [UsageProvider: ProviderMetadata] {
        Dictionary(uniqueKeysWithValues: self.all.map { ($0.id, $0.metadata) })
    }

    public static func descriptor(for id: UsageProvider) -> ProviderDescriptor {
        self.ensureBootstrapped()
        if let found = self.store.byID[id] {
            return found
        }
        if let found = self.all.first(where: { $0.id == id }) {
            return found
        }
        fatalError("Missing ProviderDescriptor for \(id.rawValue)")
    }

    public static var cliNameMap: [String: UsageProvider] {
        self.ensureBootstrapped()
        var map: [String: UsageProvider] = [:]
        for descriptor in self.all {
            map[descriptor.cli.name] = descriptor.id
            for alias in descriptor.cli.aliases {
                map[alias] = descriptor.id
            }
        }
        return map
    }
}
