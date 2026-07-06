import AppKit
import CodexBarCore
import Foundation
import Observation
import SweetCookieKit

// MARK: - Observation helpers

@MainActor
extension UsageStore {
    var menuObservationToken: Int {
        _ = self.snapshots
        _ = self.errors
        _ = self.knownLimitsAvailabilityByProvider
        _ = self.lastSourceLabels
        _ = self.lastFetchAttempts
        _ = self.accountSnapshots
        _ = self.codexAccountSnapshots
        _ = self.kiloScopeSnapshots
        _ = self.claudeSwapAccountSnapshots
        _ = self.claudeSwapLastError
        _ = self.claudeSwapRevision
        _ = self.tokenSnapshots
        _ = self.tokenErrors
        _ = self.tokenRefreshInFlight
        _ = self.credits
        _ = self.lastCreditsError
        _ = self.openAIDashboard
        _ = self.lastOpenAIDashboardError
        _ = self.openAIDashboardRequiresLogin
        _ = self.openAIDashboardAttachmentRevision
        _ = self.versions
        _ = self.isRefreshing
        _ = self.refreshingProviders
        _ = self.pathDebugInfo
        _ = self.statuses
        _ = self.probeLogs
        _ = self.historicalPaceRevision
        _ = self.planUtilizationHistoryRevision
        _ = self.providerStorageFootprints
        return 0
    }

    var iconObservationToken: Int {
        _ = self.snapshots
        _ = self.errors
        _ = self.knownLimitsAvailabilityByProvider
        _ = self.credits
        _ = self.lastCreditsError
        _ = self.openAIDashboard
        _ = self.lastOpenAIDashboardError
        _ = self.openAIDashboardRequiresLogin
        _ = self.refreshingProviders
        _ = self.statuses
        _ = self.historicalPaceRevision
        return 0
    }

    func observeSettingsChanges() {
        withObservationTracking {
            _ = self.backgroundWorkSettingsObservationToken
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeSettingsChanges()
                self.invalidateProviderAvailabilityCache()
                self.probeLogs = [:]
                guard self.startupBehavior.automaticallyStartsBackgroundWork else { return }
                self.startTimer()
                self.updateProviderRuntimes()
                await self.refreshHistoricalDatasetIfNeeded()
                await self.refreshForSettingsChange()
            }
        }
    }

    var backgroundWorkSettingsObservationToken: Int {
        _ = self.settings.refreshFrequency
        _ = self.settings.statusChecksEnabled
        _ = self.settings.sessionQuotaNotificationsEnabled
        _ = self.settings.quotaWarningNotificationsEnabled
        _ = self.settings.quotaWarningThresholds
        _ = self.settings.quotaWarningThresholds(.session)
        _ = self.settings.quotaWarningThresholds(.weekly)
        _ = self.settings.quotaWarningSoundEnabled
        _ = self.settings.usageBarsShowUsed
        _ = self.settings.costUsageEnabled
        _ = self.settings.costUsageHistoryDays
        _ = self.settings.randomBlinkEnabled
        _ = self.settings.configRevision
        for implementation in ProviderCatalog.all {
            implementation.observeSettings(self.settings)
        }
        _ = self.settings.multiAccountMenuLayout
        _ = self.settings.tokenAccountsByProvider
        _ = self.settings.mergeIcons
        _ = self.settings.debugLoadingPattern
        _ = self.settings.debugKeepCLISessionsAlive
        _ = self.settings.historicalTrackingEnabled
        _ = self.settings.providerStorageFootprintsEnabled
        return 0
    }

    var attachedOpenAIDashboardSnapshot: OpenAIDashboardSnapshot? {
        guard self.openAIDashboardAttachmentAuthorized else { return nil }
        return self.openAIDashboard
    }
}

@MainActor
@Observable
final class UsageStore {
    nonisolated static let resetBoundaryRefreshGraceSeconds: TimeInterval = 30
    nonisolated static let resetBoundaryRefreshMinimumDelaySeconds: TimeInterval = 5

    private struct ProviderAvailabilityCacheEntry {
        let available: Bool
        let configRevision: Int
        let expiresAt: Date

        func isValid(now: Date, configRevision: Int) -> Bool {
            self.configRevision == configRevision && self.expiresAt > now
        }
    }

    struct AccountInfoCacheEntry {
        let account: AccountInfo
        let configRevision: Int
        let expiresAt: Date

        func isValid(now: Date, configRevision: Int) -> Bool {
            self.configRevision == configRevision && self.expiresAt > now
        }
    }

    enum CodexCreditsSource {
        case none
        case api
        case dashboardWeb
    }

    var snapshots: [UsageProvider: UsageSnapshot] = [:]
    var errors: [UsageProvider: String] = [:]
    var geminiObservedConsumerTierDeprecation = false
    var knownLimitsAvailabilityByProvider: [UsageProvider: UsageLimitsAvailability] = [:]
    var lastSourceLabels: [UsageProvider: String] = [:]
    var lastFetchAttempts: [UsageProvider: [ProviderFetchAttempt]] = [:]
    var accountSnapshots: [UsageProvider: [TokenAccountUsageSnapshot]] = [:]
    var codexAccountSnapshots: [CodexAccountUsageSnapshot] = []
    var kiloScopeSnapshots: [KiloScopeSnapshot] = []
    var claudeSwapAccountSnapshots: [ProviderAccountUsageSnapshot] = []
    var claudeSwapLastRefreshAt: Date?
    var claudeSwapLastError: String?
    var claudeSwapDetectedVersion: String?
    var claudeSwapRevision: UInt64 = 0
    @ObservationIgnored var claudeSwapRefreshTask: Task<Void, Never>?
    @ObservationIgnored var claudeSwapTransientState = ClaudeSwapTransientState()
    var tokenSnapshots: [UsageProvider: CostUsageTokenSnapshot] = [:]
    var tokenErrors: [UsageProvider: String] = [:]
    var tokenRefreshInFlight: Set<UsageProvider> = []
    var credits: CreditsSnapshot?
    var lastCreditsError: String?
    var openAIDashboard: OpenAIDashboardSnapshot?
    var lastOpenAIDashboardError: String?
    var openAIDashboardRequiresLogin: Bool = false
    var openAIDashboardCookieImportStatus: String?
    var openAIDashboardCookieImportDebugLog: String?
    var versions: [UsageProvider: String] = [:]
    var isRefreshing = false
    var refreshingProviders: Set<UsageProvider> = []
    var debugForceAnimation = false
    var pathDebugInfo: PathDebugSnapshot = .empty
    var statuses: [UsageProvider: ProviderStatus] = [:]
    var statusComponents: [UsageProvider: [ProviderStatusComponent]] = [:]
    var probeLogs: [UsageProvider: String] = [:]
    var historicalPaceRevision: Int = 0
    var planUtilizationHistoryRevision: Int = 0
    var providerStorageFootprints: [UsageProvider: ProviderStorageFootprint] = [:]
    @ObservationIgnored var lastCreditsSnapshot: CreditsSnapshot?
    @ObservationIgnored var lastCreditsSnapshotAccountKey: String?
    @ObservationIgnored var lastCreditsSource: CodexCreditsSource = .none
    @ObservationIgnored var creditsFailureStreak: Int = 0
    @ObservationIgnored var openAIDashboardAttachmentAuthorized: Bool = false {
        didSet {
            guard self.openAIDashboardAttachmentAuthorized != oldValue else { return }
            self.openAIDashboardAttachmentRevision &+= 1
        }
    }

    var openAIDashboardAttachmentRevision = 0
    @ObservationIgnored var lastOpenAIDashboardSnapshot: OpenAIDashboardSnapshot?
    @ObservationIgnored var lastOpenAIDashboardAttachmentAuthorized: Bool = false
    @ObservationIgnored var lastOpenAIDashboardTargetEmail: String?
    @ObservationIgnored var lastOpenAIDashboardTargetIsolationKey: String?
    @ObservationIgnored var lastOpenAIDashboardAttemptAt: Date?
    @ObservationIgnored var lastOpenAIDashboardCookieImportAttemptAt: Date?
    @ObservationIgnored var lastOpenAIDashboardCookieImportEmail: String?
    @ObservationIgnored var lastCodexAccountScopedRefreshGuard: CodexAccountScopedRefreshGuard?
    @ObservationIgnored var lastKnownLiveSystemCodexEmail: String?
    @ObservationIgnored var openAIWebAccountDidChange: Bool = false
    @ObservationIgnored var creditsRefreshTask: Task<Void, Never>?
    @ObservationIgnored var creditsRefreshTaskKey: String?
    @ObservationIgnored var openAIDashboardBackgroundRefreshTask: Task<Void, Never>?
    @ObservationIgnored var openAIDashboardBackgroundRefreshTaskKey: String?
    @ObservationIgnored var openAIDashboardRefreshTask: Task<Void, Never>?
    @ObservationIgnored var openAIDashboardRefreshTaskKey: String?
    @ObservationIgnored var openAIDashboardRefreshTaskToken: UUID?
    @ObservationIgnored var _test_openAIDashboardCookieImportOverride: (@MainActor (
        String?,
        Bool,
        ProviderCookieSource,
        CookieHeaderCache.Scope?,
        @escaping (String) -> Void) async throws -> OpenAIDashboardBrowserCookieImporter.ImportResult)?
    @ObservationIgnored var _test_openAIDashboardLoaderOverride: (@MainActor (
        String?,
        @escaping (String) -> Void,
        Bool,
        TimeInterval) async throws -> OpenAIDashboardSnapshot)?
    @ObservationIgnored var _test_codexCreditsLoaderOverride: (@MainActor () async throws -> CreditsSnapshot)?
    @ObservationIgnored var _test_codexResetCreditsFetcherOverride: CodexResetCreditsFetcher?
    @ObservationIgnored var _test_widgetSnapshotSaveOverride: (@MainActor (WidgetSnapshot) async -> Void)?
    @ObservationIgnored var _test_providerRefreshOverride: (@MainActor (UsageProvider) async -> Void)?
    @ObservationIgnored var _test_tokenUsageRefreshOverride: (@MainActor (UsageProvider, Bool) async -> Void)?
    @ObservationIgnored var _test_providerStatusFetchOverride: (@MainActor (
        UsageProvider) async throws -> ProviderStatus)?
    @ObservationIgnored var _test_startupConnectivityRetryScheduled: (@MainActor (Int, TimeInterval) -> Void)?
    @ObservationIgnored var _test_startupConnectivityRetrySleepOverride: (@MainActor (
        TimeInterval) async throws -> Void)?
    @ObservationIgnored var widgetSnapshotPersistTask: Task<Void, Never>?

    @ObservationIgnored let codexFetcher: UsageFetcher
    @ObservationIgnored let claudeFetcher: any ClaudeUsageFetching
    @ObservationIgnored let costUsageFetcher: CostUsageFetcher
    @ObservationIgnored let browserDetection: BrowserDetection
    @ObservationIgnored private let registry: ProviderRegistry
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let environmentBase: [String: String]
    @ObservationIgnored private let sessionQuotaNotifier: any SessionQuotaNotifying
    @ObservationIgnored private let sessionQuotaLogger = CodexBarLog.logger(LogCategories.sessionQuota)
    @ObservationIgnored let openAIWebLogger = CodexBarLog.logger(LogCategories.openAIWeb)
    @ObservationIgnored private let tokenCostLogger = CodexBarLog.logger(LogCategories.tokenCost)
    @ObservationIgnored let augmentLogger = CodexBarLog.logger(LogCategories.augment)
    @ObservationIgnored let providerLogger = CodexBarLog.logger(LogCategories.providers)
    @ObservationIgnored let adaptiveRefreshLogger = CodexBarLog.logger(LogCategories.adaptiveRefresh)
    @ObservationIgnored var openAIWebDebugLines: [String] = []
    @ObservationIgnored var failureGates: [UsageProvider: ConsecutiveFailureGate] = [:]
    @ObservationIgnored var tokenFailureGates: [UsageProvider: ConsecutiveFailureGate] = [:]
    @ObservationIgnored var providerSpecs: [UsageProvider: ProviderSpec] = [:]
    @ObservationIgnored let providerMetadata: [UsageProvider: ProviderMetadata]
    @ObservationIgnored var providerRuntimes: [UsageProvider: any ProviderRuntime] = [:]
    @ObservationIgnored var providerRefreshCoordinator = ProviderRefreshCoordinator<UsageProvider>()
    @ObservationIgnored private var providerAvailabilityCache: [UsageProvider: ProviderAvailabilityCacheEntry] = [:]
    @ObservationIgnored var accountInfoCache: [UsageProvider: AccountInfoCacheEntry] = [:]
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    /// In-memory only; resets on every launch.
    @ObservationIgnored private(set) var lastMenuOpenAt: Date?
    @ObservationIgnored var adaptiveRefreshScheduledAt: Date?
    @ObservationIgnored private var tokenTimerTask: Task<Void, Never>?
    @ObservationIgnored private var tokenRefreshSequenceTask: Task<Void, Never>?
    @ObservationIgnored private var tokenRefreshSequenceProvider: UsageProvider?
    @ObservationIgnored var memoryPressureReliefTask: Task<Void, Never>?
    @ObservationIgnored var startupConnectivityRetryTask: Task<Void, Never>?
    @ObservationIgnored var startupConnectivityRetryNeeded = false
    @ObservationIgnored var startupConnectivityRetryRefreshActive = false
    @ObservationIgnored var storageRefreshTask: Task<Void, Never>?
    @ObservationIgnored var storageRefreshGeneration: UInt64 = 0
    @ObservationIgnored var storageRefreshInFlightSignature: String?
    @ObservationIgnored var storageRefreshInFlightRequestKey: String?
    @ObservationIgnored var lastStorageRefreshSignature: String?
    @ObservationIgnored var lastStorageRefreshRequestKey: String?
    @ObservationIgnored var lastStorageRefreshAt: Date?
    @ObservationIgnored var managedCodexAccountsForStorageOverride: [ManagedCodexAccount]?
    @ObservationIgnored private var pathDebugRefreshTask: Task<Void, Never>?
    @ObservationIgnored var resetBoundaryRefreshTask: Task<Void, Never>?
    @ObservationIgnored var scheduledResetBoundaryRefreshAt: Date?
    @ObservationIgnored var attemptedResetBoundaryRefreshes: Set<Date> = []
    @ObservationIgnored var codexPlanHistoryBackfillTask: Task<Void, Never>?
    @ObservationIgnored let historicalUsageHistoryStore: HistoricalUsageHistoryStore
    @ObservationIgnored let planUtilizationHistoryStore: PlanUtilizationHistoryStore
    @ObservationIgnored let codexAccountUsageSnapshotStore: (any CodexAccountUsageSnapshotStoring)?
    @ObservationIgnored var codexHistoricalDataset: CodexHistoricalDataset?
    @ObservationIgnored var codexHistoricalDatasetAccountKey: String?
    @ObservationIgnored var lastKnownResetSnapshots: [UsageProvider: UsageSnapshot] = [:]
    @ObservationIgnored var lastKnownSessionRemaining: [UsageProvider: Double] = [:]
    @ObservationIgnored var lastKnownSessionWindowSource: [UsageProvider: SessionQuotaWindowSource] = [:]
    @ObservationIgnored var quotaWarningState: [QuotaWarningStateKey: QuotaWarningState] = [:]
    @ObservationIgnored var lastPermissionPromptNotificationAt: [UsageProvider: Date] = [:]
    @ObservationIgnored var lastTokenFetchAt: [UsageProvider: Date] = [:]
    @ObservationIgnored var lastTokenFetchScope: [UsageProvider: String] = [:]
    @ObservationIgnored var planUtilizationHistory: [UsageProvider: PlanUtilizationHistoryBuckets] = [:]
    @ObservationIgnored var sessionLimitResetDetectorStates: [String: LimitResetDetectorState] = [:]
    @ObservationIgnored var weeklyLimitResetDetectorStates: [String: LimitResetDetectorState] = [:]
    @ObservationIgnored private var hasCompletedInitialRefresh: Bool = false
    @ObservationIgnored private let providerAvailabilityCacheTTL: TimeInterval = 1
    @ObservationIgnored let accountInfoCacheTTL: TimeInterval = 30
    @ObservationIgnored let tokenFetchTTL: TimeInterval = 60 * 60
    @ObservationIgnored private let tokenFetchTimeout: TimeInterval = 10 * 60
    @ObservationIgnored let startupBehavior: StartupBehavior
    @ObservationIgnored let planUtilizationPersistenceCoordinator: PlanUtilizationHistoryPersistenceCoordinator

    init(
        fetcher: UsageFetcher,
        browserDetection: BrowserDetection,
        claudeFetcher: (any ClaudeUsageFetching)? = nil,
        costUsageFetcher: CostUsageFetcher = CostUsageFetcher(),
        settings: SettingsStore,
        registry: ProviderRegistry = .shared,
        historicalUsageHistoryStore: HistoricalUsageHistoryStore = HistoricalUsageHistoryStore(),
        planUtilizationHistoryStore: PlanUtilizationHistoryStore = .defaultAppSupport(),
        codexAccountUsageSnapshotStore: (any CodexAccountUsageSnapshotStoring)? = nil,
        sessionQuotaNotifier: any SessionQuotaNotifying = SessionQuotaNotifier(),
        startupBehavior: StartupBehavior = .automatic,
        environmentBase: [String: String] = ProcessInfo.processInfo.environment)
    {
        self.codexFetcher = fetcher
        self.browserDetection = browserDetection
        self.claudeFetcher = claudeFetcher ?? ClaudeUsageFetcher(browserDetection: browserDetection)
        self.costUsageFetcher = costUsageFetcher
        self.settings = settings
        self.registry = registry
        self.environmentBase = environmentBase
        self.historicalUsageHistoryStore = historicalUsageHistoryStore
        self.planUtilizationHistoryStore = planUtilizationHistoryStore
        self.sessionQuotaNotifier = sessionQuotaNotifier
        self.startupBehavior = startupBehavior.resolved(isRunningTests: Self.isRunningTestsProcess())
        self.codexAccountUsageSnapshotStore = codexAccountUsageSnapshotStore ??
            (self.startupBehavior.automaticallyStartsBackgroundWork ? FileCodexAccountUsageSnapshotStore() : nil)
        self.planUtilizationPersistenceCoordinator = PlanUtilizationHistoryPersistenceCoordinator(
            store: planUtilizationHistoryStore)
        self.providerMetadata = registry.metadata
        self
            .failureGates = Dictionary(
                uniqueKeysWithValues: UsageProvider.allCases
                    .map { ($0, ConsecutiveFailureGate()) })
        self.tokenFailureGates = Dictionary(
            uniqueKeysWithValues: UsageProvider.allCases
                .map { ($0, ConsecutiveFailureGate()) })
        self.providerSpecs = registry.specs(
            settings: settings,
            metadata: self.providerMetadata,
            codexFetcher: fetcher,
            claudeFetcher: self.claudeFetcher,
            browserDetection: browserDetection,
            environmentBase: environmentBase)
        self.providerRuntimes = Dictionary(uniqueKeysWithValues: ProviderCatalog.all.compactMap { implementation in
            implementation.makeRuntime().map { (implementation.id, $0) }
        })
        self.planUtilizationHistory = planUtilizationHistoryStore.load()
        self.sessionLimitResetDetectorStates = Self.loadLimitResetDetectorStates(
            from: settings.userDefaults,
            defaultsKey: Self.sessionLimitResetDetectorDefaultsKey,
            logName: "session")
        self.weeklyLimitResetDetectorStates = Self.loadWeeklyLimitResetDetectorStates(from: settings.userDefaults)
        if let codexAccountUsageSnapshotStore = self.codexAccountUsageSnapshotStore {
            self.codexAccountSnapshots = codexAccountUsageSnapshotStore.load(
                for: self.freshCodexVisibleAccountsForSnapshotHydration())
        }
        self.logStartupState()
        self.bindSettings()
        self.pathDebugInfo = PathDebugSnapshot(
            codexBinary: nil,
            claudeBinary: nil,
            geminiBinary: nil,
            effectivePATH: PathBuilder.effectivePATH(purposes: [.rpc, .tty, .nodeTooling]),
            loginShellPATH: LoginShellPathCache.shared.current?.joined(separator: ":"))
        guard self.startupBehavior.automaticallyStartsBackgroundWork else { return }
        self.hydrateCachedTokenSnapshots()
        self.detectVersions()
        self.updateProviderRuntimes()
        Task { @MainActor [weak self] in
            self?.schedulePathDebugInfoRefresh()
        }
        LoginShellPathCache.shared.captureOnce { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.schedulePathDebugInfoRefresh()
            }
        }
        Task { @MainActor [weak self] in
            await self?.refreshHistoricalDatasetIfNeeded()
        }
        Task { await self.refresh() }
        self.startTimer()
        self.startTokenTimer()
    }

    private static func isRunningTestsProcess() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCTestSessionIdentifier"] != nil { return true }
        if environment["SWIFT_TESTING_ENABLED"] != nil { return true }
        return CommandLine.arguments.contains { argument in
            argument.contains("xctest") || argument.contains("swift-testing")
        }
    }

    /// Returns the login method (plan type) for the specified provider, if available.
    private func loginMethod(for provider: UsageProvider) -> String? {
        self.snapshots[provider]?.loginMethod(for: provider)
    }

    /// Returns true if the Claude account appears to be a subscription (Max, Pro, Ultra, Team).
    /// Returns false for API users or when plan cannot be determined.
    func isClaudeSubscription() -> Bool {
        Self.isSubscriptionPlan(self.loginMethod(for: .claude))
    }

    /// Determines if a login method string indicates a Claude subscription plan.
    /// Known subscription indicators: Max, Pro, Ultra, Team (case-insensitive).
    nonisolated static func isSubscriptionPlan(_ loginMethod: String?) -> Bool {
        ClaudePlan.isSubscriptionLoginMethod(loginMethod)
    }

    var preferredSnapshot: UsageSnapshot? {
        for provider in self.enabledProviders() {
            if let snap = self.snapshots[provider] { return snap }
        }
        return nil
    }

    var iconStyle: IconStyle {
        let enabled = self.enabledProviders()
        if enabled.count > 1 { return .combined }
        if let provider = enabled.first {
            return self.style(for: provider)
        }
        return .codex
    }

    var isStale: Bool {
        for provider in self.enabledProviders() where self.errors[provider] != nil {
            return true
        }
        return false
    }

    func enabledProviders() -> [UsageProvider] {
        // Use cached enablement to avoid repeated UserDefaults lookups in animation ticks.
        let enabled = self.settings.enabledProvidersOrdered(metadataByProvider: self.providerMetadata)
        let now = Date()
        return enabled.filter { self.isProviderAvailable($0, now: now) }
    }

    /// Enabled providers without availability filtering. Used for display (switcher, merge-icons).
    func enabledProvidersForDisplay() -> [UsageProvider] {
        self.settings.enabledProvidersOrdered(metadataByProvider: self.providerMetadata)
    }

    /// Providers that should actually participate in background refresh/status/token work.
    func enabledProvidersForBackgroundWork() -> [UsageProvider] {
        self.enabledProviders()
    }

    var statusChecksEnabled: Bool {
        self.settings.statusChecksEnabled
    }

    func metadata(for provider: UsageProvider) -> ProviderMetadata {
        self.providerMetadata[provider]!
    }

    var codexBrowserCookieOrder: BrowserCookieImportOrder {
        self.metadata(for: .codex).browserCookieOrder ?? Browser.defaultImportOrder
    }

    func snapshot(for provider: UsageProvider) -> UsageSnapshot? {
        self.snapshots[provider]
    }

    func sourceLabel(for provider: UsageProvider) -> String {
        var label = self.lastSourceLabels[provider] ?? ""
        if label.isEmpty {
            let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
            let modes = descriptor.fetchPlan.sourceModes
            if modes.count == 1, let mode = modes.first {
                label = mode.rawValue
            } else {
                let context = ProviderSourceLabelContext(
                    provider: provider,
                    settings: self.settings,
                    store: self,
                    descriptor: descriptor)
                label = ProviderCatalog.implementation(for: provider)?
                    .defaultSourceLabel(context: context)
                    ?? "auto"
            }
        }

        let context = ProviderSourceLabelContext(
            provider: provider,
            settings: self.settings,
            store: self,
            descriptor: ProviderDescriptorRegistry.descriptor(for: provider))
        return ProviderCatalog.implementation(for: provider)?
            .decorateSourceLabel(context: context, baseLabel: label)
            ?? label
    }

    func fetchAttempts(for provider: UsageProvider) -> [ProviderFetchAttempt] {
        self.lastFetchAttempts[provider] ?? []
    }

    func style(for provider: UsageProvider) -> IconStyle {
        self.providerSpecs[provider]?.style ?? .codex
    }

    func isStale(provider: UsageProvider) -> Bool {
        self.errors[provider] != nil
    }

    func knownLimitsAvailability(for provider: UsageProvider) -> UsageLimitsAvailability? {
        self.knownLimitsAvailabilityByProvider[provider]
    }

    func hasSatisfiedUsageFetch(for provider: UsageProvider) -> Bool {
        self.snapshot(for: provider) != nil || self.knownLimitsAvailability(for: provider)?.isUnavailable == true
    }

    func needsUsageRefreshRetry(for provider: UsageProvider) -> Bool {
        self.isStale(provider: provider) || !self.hasSatisfiedUsageFetch(for: provider)
    }

    func isEnabled(_ provider: UsageProvider) -> Bool {
        let enabled = self.settings.isProviderEnabledCached(
            provider: provider,
            metadataByProvider: self.providerMetadata)
        guard enabled else { return false }
        return self.isProviderAvailable(provider)
    }

    func isProviderAvailable(_ provider: UsageProvider) -> Bool {
        self.isProviderAvailable(provider, now: Date())
    }

    private func isProviderAvailable(_ provider: UsageProvider, now: Date) -> Bool {
        guard provider != .codex else { return true }

        let configRevision = self.settings.configRevision
        if let cached = self.providerAvailabilityCache[provider],
           cached.isValid(now: now, configRevision: configRevision)
        {
            return cached.available
        }

        // Availability should mirror the effective fetch environment, including token-account overrides.
        // Otherwise providers (notably token-account-backed API providers) can fetch successfully but be
        // hidden from the menu because their credentials are not in ProcessInfo's environment.
        let environment = ProviderRegistry.makeEnvironment(
            base: self.environmentBase,
            provider: provider,
            settings: self.settings,
            tokenOverride: nil)
        let context = ProviderAvailabilityContext(
            provider: provider,
            settings: self.settings,
            environment: environment)
        let available = ProviderCatalog.implementation(for: provider)?
            .isAvailable(context: context)
            ?? true
        self.providerAvailabilityCache[provider] = ProviderAvailabilityCacheEntry(
            available: available,
            configRevision: configRevision,
            expiresAt: now.addingTimeInterval(self.providerAvailabilityCacheTTL))
        return available
    }

    private func invalidateProviderAvailabilityCache() {
        self.providerAvailabilityCache.removeAll(keepingCapacity: true)
    }

    func performRuntimeAction(_ action: ProviderRuntimeAction, for provider: UsageProvider) async {
        guard let runtime = self.providerRuntimes[provider] else { return }
        let context = ProviderRuntimeContext(provider: provider, settings: self.settings, store: self)
        await runtime.perform(action: action, context: context)
    }

    private func updateProviderRuntimes() {
        for (provider, runtime) in self.providerRuntimes {
            let context = ProviderRuntimeContext(provider: provider, settings: self.settings, store: self)
            if self.isEnabled(provider) {
                runtime.start(context: context)
            } else {
                runtime.stop(context: context)
            }
            runtime.settingsDidChange(context: context)
        }
    }

    func refresh(forceTokenUsage: Bool = false) async {
        await self.runRefresh(forceTokenUsage: forceTokenUsage, startupConnectivityRetryAttempt: nil)
    }

    func noteMenuOpened(at date: Date = Date()) {
        self.lastMenuOpenAt = date
        guard self.settings.refreshFrequency == .adaptive else { return }

        let decision = Self.adaptiveRefreshDecision(
            now: date,
            lastMenuOpenAt: date,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState)
        let candidate = date.addingTimeInterval(TimeInterval(decision.delay.components.seconds))
        guard Self.shouldAdvanceAdaptiveTimer(
            scheduledAt: self.adaptiveRefreshScheduledAt,
            candidate: candidate)
        else { return }
        self.startTimer(preservingResetBoundaryRefresh: true)
    }

    #if DEBUG
    @ObservationIgnored private(set) var completedRefreshCountForTesting = 0
    #endif

    func runRefresh(
        forceTokenUsage: Bool = false,
        startupConnectivityRetryAttempt: Int?,
        coalesceProviderRefreshesOverride: Bool? = nil) async
    {
        guard !self.isRefreshing else { return }
        self.prepareRefreshState()
        let refreshPhase = Self.refreshPhase(hasCompletedInitialRefresh: self.hasCompletedInitialRefresh)
        let openAIWebRefreshPhase = Self.openAIWebRefreshPhase(
            providerRefreshPhase: refreshPhase,
            startupConnectivityRetryAttempt: startupConnectivityRetryAttempt)
        let allowsStartupConnectivityRetry = refreshPhase == .startup || startupConnectivityRetryAttempt != nil
        self.startupConnectivityRetryRefreshActive = allowsStartupConnectivityRetry
        self.startupConnectivityRetryNeeded = false
        let displayEnabledProviders = self.enabledProvidersForDisplay()
        let enabledProviderSet = Set(displayEnabledProviders)
        let refreshProviders = self.enabledProvidersForBackgroundWork()
        let availableRefreshProviders = Set(self.enabledProviders())
        let refreshStartedAt = Date()

        await ProviderRefreshContext.$current.withValue(refreshPhase) {
            self.isRefreshing = true
            defer {
                self.isRefreshing = false
                self.hasCompletedInitialRefresh = true
                self.startupConnectivityRetryRefreshActive = false
            }

            self.clearDisabledProviderState(enabledProviders: enabledProviderSet)
            self.clearUnavailableProviderState(
                displayEnabledProviders: enabledProviderSet,
                availableProviders: availableRefreshProviders)
            self.scheduleStorageFootprintRefresh(for: displayEnabledProviders)

            await withTaskGroup(of: Void.self) { group in
                for provider in refreshProviders {
                    group.addTask {
                        await self.refreshProvider(
                            provider,
                            coalesceIfRefreshing: coalesceProviderRefreshesOverride ??
                                (ProviderInteractionContext.current == .background))
                    }
                    if availableRefreshProviders.contains(provider) {
                        group.addTask { await self.refreshProviderStatus(provider) }
                    }
                }
                if forceTokenUsage {
                    group.addTask { await self.refreshCreditsNow(minimumSnapshotUpdatedAt: refreshStartedAt) }
                }
            }

            if !forceTokenUsage {
                self.scheduleCreditsRefreshIfNeeded(minimumSnapshotUpdatedAt: refreshStartedAt)
            }

            if forceTokenUsage {
                await self.refreshTokenUsageSequenceNow(force: true)
            } else {
                // Token-cost usage can be slow; run it outside regular/menu-open refreshes so we don't block UI.
                self.scheduleTokenRefresh(force: false)
            }

            // OpenAI web scrape depends on the current Codex account email (which can change after login/account
            // switch). Run this after Codex usage refresh so we don't accidentally scrape with stale credentials.
            self.syncOpenAIWebState()
            let refreshPolicy = OpenAIWebRefreshPolicyContext(
                accessEnabled: self.isEnabled(.codex) &&
                    self.settings.openAIWebAccessEnabled &&
                    self.settings.codexCookieSource.isEnabled,
                batterySaverEnabled: self.settings.openAIWebBatterySaverEnabled,
                force: forceTokenUsage,
                refreshPhase: openAIWebRefreshPhase)
            let shouldRefreshOpenAIWeb = Self.shouldRunOpenAIWebRefresh(refreshPolicy)
            self.openAIWebLogger.debug(
                "OpenAI web refresh gate",
                metadata: [
                    "allowed": shouldRefreshOpenAIWeb ? "1" : "0",
                    "accessEnabled": refreshPolicy.accessEnabled ? "1" : "0",
                    "batterySaverEnabled": refreshPolicy.batterySaverEnabled ? "1" : "0",
                    "force": refreshPolicy.force ? "1" : "0",
                    "interaction": ProviderInteractionContext.current == .userInitiated ? "user" : "background",
                    "phase": openAIWebRefreshPhase == .startup ? "startup" : "regular",
                ])
            if shouldRefreshOpenAIWeb {
                let codexDashboardGuard = self.freshCodexOpenAIWebRefreshGuard()
                if forceTokenUsage {
                    await self.refreshOpenAIDashboardIfNeeded(
                        force: true,
                        expectedGuard: codexDashboardGuard)
                } else {
                    self.scheduleOpenAIDashboardRefreshIfNeeded(expectedGuard: codexDashboardGuard)
                }
            }

            if forceTokenUsage, self.openAIDashboardRequiresLogin {
                await self.refreshProvider(.codex)
                await self.refreshCreditsNow(minimumSnapshotUpdatedAt: refreshStartedAt)
            }

            self.persistWidgetSnapshot(reason: "refresh")
        }

        self.scheduleResetBoundaryRefreshIfNeeded(
            normalRefreshInterval: self.normalRefreshIntervalForHeuristics())

        if allowsStartupConnectivityRetry {
            self.completeStartupConnectivityRetryPass(currentAttempt: startupConnectivityRetryAttempt ?? 0)
        }
        if refreshPhase == .startup {
            self.scheduleMemoryPressureRelief()
        }
        #if DEBUG
        self.completedRefreshCountForTesting += 1
        #endif
    }

    /// For demo/testing: drop the snapshot so the loading animation plays, then restore the last snapshot.
    func replayLoadingAnimation(duration: TimeInterval = 3) {
        let current = self.preferredSnapshot
        self.snapshots.removeAll()
        self.debugForceAnimation = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            if let current, let provider = self.enabledProviders().first {
                self.snapshots[provider] = current
            }
            self.debugForceAnimation = false
        }
    }

    // MARK: - Private

    private func bindSettings() {
        self.observeSettingsChanges()
    }

    #if DEBUG
    @ObservationIgnored private(set) var refreshTimerSleepOverrideForTesting: Duration?

    /// Sets this store's timer sleep override and restarts the timer with it applied, so tests can
    /// observe multiple fixed/adaptive ticks without waiting real minutes. The reason/delay a tick
    /// computes and logs is unaffected; only how long it sleeps before acting on that decision
    /// changes. Instance-scoped (not a shared global) so concurrently running tests, each with their
    /// own `UsageStore`, cannot clobber one another's override.
    func restartTimerWithSleepOverrideForTesting(_ duration: Duration?) {
        self.refreshTimerSleepOverrideForTesting = duration
        self.startTimer()
    }
    #endif

    private func startTimer(preservingResetBoundaryRefresh: Bool = false) {
        self.timerTask?.cancel()
        self.adaptiveRefreshScheduledAt = nil
        if !preservingResetBoundaryRefresh {
            self.cancelResetBoundaryRefresh()
        }

        let frequency = self.settings.refreshFrequency
        guard frequency != .manual else { return }

        if frequency == .adaptive {
            // Background poller so the menu stays responsive; canceled when settings change or store
            // deallocates. Delay is recomputed before every tick from live power/thermal state and the
            // in-memory menu-open signal; the policy itself stays pure (Input is built here). `self` is
            // only strongly held for the brief, synchronous decision computation below, never across
            // the sleep — a weak reference lets the store deallocate mid-sleep, same as fixed mode.
            self.timerTask = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    guard let sleepDuration = await Self.nextAdaptiveTimerSleepDuration(for: self) else { return }
                    try? await Task.sleep(for: sleepDuration)
                    guard !Task.isCancelled else { return }
                    await self?.refresh()
                }
            }
            return
        }

        guard let wait = frequency.seconds else { return }

        // Background poller so the menu stays responsive; canceled when settings change or store deallocates.
        // `self` is only briefly borrowed to read the (DEBUG-only) sleep override, never held across the sleep.
        self.timerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let sleepDuration = await self?.effectiveTimerSleepDuration(.seconds(wait)) ?? .seconds(wait)
                try? await Task.sleep(for: sleepDuration)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private func startTokenTimer() {
        self.tokenTimerTask?.cancel()
        let wait = self.tokenFetchTTL
        self.tokenTimerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait))
                await self?.scheduleTokenRefresh(force: false)
            }
        }
    }

    private func scheduleTokenRefresh(force: Bool) {
        if force {
            self.tokenRefreshSequenceTask?.cancel()
            self.tokenRefreshSequenceTask = nil
        } else if self.tokenRefreshSequenceTask != nil {
            return
        }

        self.tokenRefreshSequenceTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.tokenRefreshSequenceTask = nil
                }
            }
            await self.refreshTokenUsageSequence(force: force)
        }
    }

    private func refreshTokenUsageSequenceNow(force: Bool) async {
        await self.drainScheduledTokenRefreshIfNeeded(force: force, scopedTo: nil)
        await self.refreshTokenUsageSequence(force: force)
    }

    func refreshTokenUsageNow(for provider: UsageProvider, force: Bool) async {
        await self.drainScheduledTokenRefreshIfNeeded(force: force, scopedTo: provider)
        await self.refreshTokenUsage(provider, force: force)
        self.scheduleMemoryPressureRelief()
    }

    private func drainScheduledTokenRefreshIfNeeded(force: Bool, scopedTo provider: UsageProvider?) async {
        guard force, let existing = self.tokenRefreshSequenceTask else { return }
        if let provider, self.tokenRefreshSequenceProvider != provider { return }
        existing.cancel()
        await existing.value
        self.tokenRefreshSequenceTask = nil
    }

    private func refreshTokenUsageSequence(force: Bool) async {
        defer { self.tokenRefreshSequenceProvider = nil }
        for provider in self.enabledProvidersForBackgroundWork() {
            if Task.isCancelled { break }
            self.tokenRefreshSequenceProvider = provider
            await self.refreshTokenUsage(provider, force: force)
            self.tokenRefreshSequenceProvider = nil
        }
        self.scheduleMemoryPressureRelief()
    }

    deinit {
        self.timerTask?.cancel()
        self.tokenTimerTask?.cancel()
        self.tokenRefreshSequenceTask?.cancel()
        self.memoryPressureReliefTask?.cancel()
        self.startupConnectivityRetryTask?.cancel()
        self.storageRefreshTask?.cancel()
        self.codexPlanHistoryBackfillTask?.cancel()
        self.resetBoundaryRefreshTask?.cancel()
    }

    enum SessionQuotaWindowSource: String {
        case primary
        case copilotSecondaryFallback
        case zaiTertiary
        case antigravityQuotaSummary
        case antigravityLegacy
    }

    struct QuotaWarningStateKey: Hashable {
        let provider: UsageProvider
        let window: QuotaWarningWindow
        /// Distinguishes independent extra rate windows that share a provider/window lane
        /// (e.g. multiple `claude-weekly-scoped-*` windows) so their fired-threshold state
        /// does not clobber each other or the primary session/weekly lanes. `nil` for the
        /// primary session and weekly lanes.
        let windowID: String?

        init(provider: UsageProvider, window: QuotaWarningWindow, windowID: String? = nil) {
            self.provider = provider
            self.window = window
            self.windowID = windowID
        }
    }

    struct QuotaWarningState {
        var lastRemaining: Double?
        var firedThresholds: Set<Int> = []
        var source: SessionQuotaWindowSource?
    }

    func postQuotaWarning(_ event: QuotaWarningEvent, provider: UsageProvider) {
        self.sessionQuotaNotifier.postQuotaWarning(
            event: event,
            provider: provider,
            soundEnabled: self.settings.quotaWarningSoundEnabled,
            onScreenAlertEnabled: self.settings.quotaWarningOnScreenAlertEnabled)
    }

    func handleSessionQuotaTransition(provider: UsageProvider, snapshot: UsageSnapshot) {
        // Session quota notifications are tied to the primary session window. Copilot free plans can
        // expose only chat quota, so allow Copilot to fall back to secondary for transition tracking.
        // Command Code synthesizes a depleted primary while subscription enrichment is unavailable.
        // Preserve the prior notification state for that placeholder, but accept positive credit data.
        if provider == .commandcode,
           snapshot.commandCodeSubscriptionEnrichmentUnavailable,
           SessionQuotaNotificationLogic.isDepleted(snapshot.primary?.remainingPercent)
        {
            return
        }
        guard let sessionWindow = self.sessionQuotaWindow(provider: provider, snapshot: snapshot) else {
            if provider == .commandcode, snapshot.commandCodeSubscriptionEnrichmentUnavailable { return }
            self.lastKnownSessionRemaining.removeValue(forKey: provider)
            self.lastKnownSessionWindowSource.removeValue(forKey: provider)
            return
        }
        let currentRemaining = sessionWindow.window.remainingPercent
        let currentSource = sessionWindow.source
        let previousRemaining = self.lastKnownSessionRemaining[provider]
        let previousSource = self.lastKnownSessionWindowSource[provider]

        if let previousSource, previousSource != currentSource {
            let providerText = provider.rawValue
            self.sessionQuotaLogger.debug(
                "session window source changed: provider=\(providerText) prevSource=\(previousSource.rawValue) " +
                    "currSource=\(currentSource.rawValue) curr=\(currentRemaining)")
            self.lastKnownSessionRemaining[provider] = currentRemaining
            self.lastKnownSessionWindowSource[provider] = currentSource
            return
        }

        defer {
            self.lastKnownSessionRemaining[provider] = currentRemaining
            self.lastKnownSessionWindowSource[provider] = currentSource
        }

        guard self.settings.sessionQuotaNotificationsEnabled else {
            if SessionQuotaNotificationLogic.isDepleted(currentRemaining) ||
                SessionQuotaNotificationLogic.isDepleted(previousRemaining)
            {
                let providerText = provider.rawValue
                let message =
                    "notifications disabled: provider=\(providerText) " +
                    "prev=\(previousRemaining ?? -1) curr=\(currentRemaining)"
                self.sessionQuotaLogger.debug(message)
            }
            return
        }

        guard previousRemaining != nil else {
            if SessionQuotaNotificationLogic.isDepleted(currentRemaining) {
                let providerText = provider.rawValue
                let message = "startup depleted: provider=\(providerText) curr=\(currentRemaining)"
                self.sessionQuotaLogger.info(message)
                self.sessionQuotaNotifier.post(transition: .depleted, provider: provider, badge: nil)
            }
            return
        }

        let transition = SessionQuotaNotificationLogic.transition(
            previousRemaining: previousRemaining,
            currentRemaining: currentRemaining)
        guard transition != .none else {
            if SessionQuotaNotificationLogic.isDepleted(currentRemaining) ||
                SessionQuotaNotificationLogic.isDepleted(previousRemaining)
            {
                let providerText = provider.rawValue
                let message =
                    "no transition: provider=\(providerText) " +
                    "prev=\(previousRemaining ?? -1) curr=\(currentRemaining)"
                self.sessionQuotaLogger.debug(message)
            }
            return
        }

        let providerText = provider.rawValue
        let transitionText = String(describing: transition)
        let message =
            "transition \(transitionText): provider=\(providerText) " +
            "prev=\(previousRemaining ?? -1) curr=\(currentRemaining)"
        self.sessionQuotaLogger.info(message)

        self.sessionQuotaNotifier.post(transition: transition, provider: provider, badge: nil)
    }

    func refreshProviderStatus(_ provider: UsageProvider) async {
        guard self.settings.statusChecksEnabled else { return }
        guard let meta = self.providerMetadata[provider] else { return }

        do {
            let status: ProviderStatus
            var components: [ProviderStatusComponent]?
            if let override = self._test_providerStatusFetchOverride {
                status = try await override(provider)
            } else if let urlString = meta.statusPageURL, let baseURL = URL(string: urlString) {
                let summary = try await Self.fetchStatusSummary(from: baseURL)
                status = summary.status
                components = summary.components
            } else if let productID = meta.statusWorkspaceProductID {
                status = try await Self.fetchWorkspaceStatus(productID: productID)
            } else {
                return
            }
            await MainActor.run {
                self.statuses[provider] = status
                // A component endpoint is best-effort. Preserve the last good list when the
                // overall status succeeds but the component request or decoding fails.
                if let components {
                    self.statusComponents[provider] = components
                }
            }
        } catch {
            self.recordStartupConnectivityRetryableFailure(error)
            // Keep the previous status to avoid flapping when the API hiccups.
            await MainActor.run {
                if self.statuses[provider] == nil {
                    self.statuses[provider] = ProviderStatus(
                        indicator: .unknown,
                        description: error.localizedDescription,
                        updatedAt: nil)
                }
            }
        }
    }
}

extension UsageStore {
    func debugDumpClaude() async {
        let fetcher = ClaudeUsageFetcher(
            browserDetection: self.browserDetection,
            keepCLISessionsAlive: self.settings.debugKeepCLISessionsAlive)
        let output = await fetcher.debugRawProbe(model: "sonnet")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codexbar-claude-probe.txt")
        try? output.write(to: url, atomically: true, encoding: .utf8)
        await MainActor.run {
            let snippet = String(output.prefix(180)).replacingOccurrences(of: "\n", with: " ")
            self.knownLimitsAvailabilityByProvider.removeValue(forKey: .claude)
            self.errors[.claude] = "[Claude] \(snippet) (saved: \(url.path))"
            NSWorkspace.shared.open(url)
        }
    }

    func dumpLog(toFileFor provider: UsageProvider) async -> URL? {
        let text = await self.debugLog(for: provider)
        let filename = "codexbar-\(provider.rawValue)-probe.txt"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            _ = await MainActor.run { NSWorkspace.shared.open(url) }
            return url
        } catch {
            await MainActor.run {
                self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider)
                self.errors[provider] = "Failed to save log: \(error.localizedDescription)"
            }
            return nil
        }
    }

    func debugAugmentDump() async -> String {
        await AugmentStatusProbe.latestDumps()
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func debugLog(for provider: UsageProvider) async -> String {
        if let cached = self.probeLogs[provider], !cached.isEmpty {
            return cached
        }

        let claudeWebExtrasEnabled = self.settings.claudeWebExtrasEnabled
        let claudeUsageDataSource = self.settings.claudeUsageDataSource
        let claudeCookieSource = self.settings.claudeCookieSource
        let claudeCookieHeader = self.settings.claudeCookieHeader
        let claudeDebugConfiguration: ClaudeDebugLogConfiguration? = if provider == .claude {
            await self.makeClaudeDebugConfiguration(
                fallbackUsageDataSource: claudeUsageDataSource,
                fallbackWebExtrasEnabled: claudeWebExtrasEnabled,
                fallbackCookieSource: claudeCookieSource,
                fallbackCookieHeader: claudeCookieHeader)
        } else {
            nil
        }
        let cursorCookieSource = self.settings.cursorCookieSource
        let cursorCookieHeader = self.settings.cursorCookieHeader
        let ampCookieSource = self.settings.ampCookieSource
        let ampCookieHeader = self.settings.ampCookieHeader
        let ollamaCookieSource = self.settings.ollamaCookieSource
        let ollamaCookieHeader = self.settings.ollamaCookieHeader
        let processEnvironment = self.environmentBase
        let openAIDebugContext = self.openAIAPIKeyDebugContext(processEnvironment: processEnvironment)
        let azureOpenAIDebugContext = self.azureOpenAIAPIKeyDebugContext(processEnvironment: processEnvironment)
        let openRouterDebugContext = self.openRouterAPIKeyDebugContext(processEnvironment: processEnvironment)
        let crossModelDebugContext = self.crossModelAPIKeyDebugContext(processEnvironment: processEnvironment)
        let elevenLabsDebugContext = self.elevenLabsAPIKeyDebugContext(processEnvironment: processEnvironment)
        let deepSeekHasEnvToken = DeepSeekSettingsReader.apiKey(environment: processEnvironment) != nil
        let deepSeekHasTokenAccount = self.settings.selectedTokenAccount(for: .deepseek) != nil
        let deepSeekEnvironment = ProviderRegistry.makeEnvironment(
            base: processEnvironment,
            provider: .deepseek,
            settings: self.settings,
            tokenOverride: nil)
        let codexFetcher = self.codexFetcher
        let browserDetection = self.browserDetection
        let claudeDebugExecutionContext = self.currentClaudeDebugExecutionContext()
        let text = await Task.detached(priority: .utility) { () -> String in
            let unimplementedDebugLogMessages: [UsageProvider: String] = [
                .gemini: "Gemini debug log not yet implemented",
                .antigravity: "Antigravity debug log not yet implemented",
                .opencode: "OpenCode debug log not yet implemented",
                .alibaba: "Alibaba Coding Plan debug log not yet implemented",
                .alibabatokenplan: "Alibaba Token Plan debug log not yet implemented",
                .factory: "Droid debug log not yet implemented",
                .copilot: "Copilot debug log not yet implemented",
                .manus: "Manus debug log not yet implemented",
                .vertexai: "Vertex AI debug log not yet implemented",
                .kilo: "Kilo debug log not yet implemented",
                .kiro: "Kiro debug log not yet implemented",
                .kimi: "Kimi debug log not yet implemented",
                .kimik2: "Kimi K2 debug log not yet implemented",
                .jetbrains: "JetBrains AI debug log not yet implemented",
                .mimo: "Xiaomi MiMo debug log not yet implemented",
                .doubao: "Doubao debug log not yet implemented",
                .sakana: "Sakana AI debug log not yet implemented",
                .venice: "Venice debug log not yet implemented",
                .commandcode: "Command Code debug log not yet implemented",
                .qoder: "Qoder debug log not yet implemented",
                .stepfun: "StepFun debug log not yet implemented",
                .bedrock: "Bedrock debug log not yet implemented",
                .grok: "Grok debug log not yet implemented",
                .groq: "Groq debug log not yet implemented",
                .t3chat: "T3 Chat debug log not yet implemented",
                .llmproxy: "LLM Proxy debug log not yet implemented",
                .litellm: "LiteLLM debug log not yet implemented",
                .deepgram: "Deepgram debug log not yet implemented",
                .chutes: "Chutes debug log not yet implemented",
                .clawrouter: "ClawRouter debug log not yet implemented",
            ]
            let buildText = {
                switch provider {
                case .codex:
                    return await codexFetcher.debugRawRateLimits()
                case .openai:
                    return Self.apiKeyDebugLine(openAIDebugContext)
                case .azureopenai:
                    return Self.apiKeyDebugLine(azureOpenAIDebugContext)
                case .claude:
                    guard let claudeDebugConfiguration else {
                        return "Claude debug log configuration unavailable"
                    }
                    return await claudeDebugExecutionContext.apply {
                        await Self.debugClaudeLog(
                            browserDetection: browserDetection,
                            configuration: claudeDebugConfiguration)
                    }
                case .zai:
                    let resolution = ProviderTokenResolver.zaiResolution()
                    let hasAny = resolution != nil
                    let source = resolution?.source.rawValue ?? "none"
                    return "Z_AI_API_KEY=\(hasAny ? "present" : "missing") source=\(source)"
                case .synthetic:
                    let resolution = ProviderTokenResolver.syntheticResolution()
                    let hasAny = resolution != nil
                    let source = resolution?.source.rawValue ?? "none"
                    return "SYNTHETIC_API_KEY=\(hasAny ? "present" : "missing") source=\(source)"
                case .cursor:
                    return await Self.debugCursorLog(
                        browserDetection: browserDetection,
                        cursorCookieSource: cursorCookieSource,
                        cursorCookieHeader: cursorCookieHeader)
                case .minimax:
                    let tokenResolution = ProviderTokenResolver.minimaxTokenResolution()
                    let cookieResolution = ProviderTokenResolver.minimaxCookieResolution()
                    let tokenSource = tokenResolution?.source.rawValue ?? "none"
                    let cookieSource = cookieResolution?.source.rawValue ?? "none"
                    return "MINIMAX_API_KEY=\(tokenResolution == nil ? "missing" : "present") " +
                        "source=\(tokenSource) MINIMAX_COOKIE=\(cookieResolution == nil ? "missing" : "present") " +
                        "source=\(cookieSource)"
                case .alibaba:
                    let resolution = ProviderTokenResolver.alibabaTokenResolution()
                    let hasAny = resolution != nil
                    let source = resolution?.source.rawValue ?? "none"
                    return "ALIBABA_CODING_PLAN_API_KEY=\(hasAny ? "present" : "missing") source=\(source)"
                case .augment:
                    return await Self.debugAugmentLog()
                case .amp:
                    return await Self.debugAmpLog(
                        browserDetection: browserDetection,
                        ampCookieSource: ampCookieSource,
                        ampCookieHeader: ampCookieHeader)
                case .ollama:
                    return await Self.debugOllamaLog(
                        browserDetection: browserDetection,
                        ollamaCookieSource: ollamaCookieSource,
                        ollamaCookieHeader: ollamaCookieHeader)
                case .openrouter:
                    return Self.apiKeyDebugLine(openRouterDebugContext)
                case .crossmodel:
                    return Self.apiKeyDebugLine(crossModelDebugContext)
                case .elevenlabs:
                    return Self.apiKeyDebugLine(elevenLabsDebugContext)
                case .warp:
                    let resolution = ProviderTokenResolver.warpResolution()
                    let hasAny = resolution != nil
                    let source = resolution?.source.rawValue ?? "none"
                    return "WARP_API_KEY=\(hasAny ? "present" : "missing") source=\(source)"
                case .deepseek:
                    return Self.apiKeyDebugLine(
                        label: "DEEPSEEK_API_KEY",
                        resolution: ProviderTokenResolver.deepseekResolution(environment: deepSeekEnvironment),
                        configToken: nil,
                        hasEnvToken: deepSeekHasEnvToken,
                        hasTokenAccount: deepSeekHasTokenAccount)
                case .gemini, .antigravity, .opencode, .opencodego, .alibabatokenplan, .factory, .copilot, .devin,
                     .vertexai, .kilo, .kiro, .kimi, .kimik2, .moonshot, .jetbrains, .perplexity, .mimo, .doubao,
                     .sakana, .abacus, .mistral, .codebuff, .crof, .windsurf, .venice, .manus, .commandcode, .qoder,
                     .stepfun,
                     .bedrock, .grok, .groq, .t3chat, .llmproxy, .litellm, .zed, .deepgram, .poe, .chutes,
                     .clawrouter:
                    return unimplementedDebugLogMessages[provider] ?? "Debug log not yet implemented"
                }
            }
            return await claudeDebugExecutionContext.apply {
                await buildText()
            }
        }.value
        self.probeLogs[provider] = text
        return text
    }

    private func makeClaudeDebugConfiguration(
        fallbackUsageDataSource: ClaudeUsageDataSource,
        fallbackWebExtrasEnabled: Bool,
        fallbackCookieSource: ProviderCookieSource,
        fallbackCookieHeader: String) async -> ClaudeDebugLogConfiguration
    {
        await MainActor.run {
            let sourceMode = self.sourceMode(for: .claude)
            let snapshot = ProviderRegistry.makeSettingsSnapshot(settings: self.settings, tokenOverride: nil)
            let environment = ProviderRegistry.makeEnvironment(
                base: self.environmentBase,
                provider: .claude,
                settings: self.settings,
                tokenOverride: nil)
            let claudeSettings = snapshot.claude ?? ProviderSettingsSnapshot.ClaudeProviderSettings(
                usageDataSource: fallbackUsageDataSource,
                webExtrasEnabled: fallbackWebExtrasEnabled,
                cookieSource: fallbackCookieSource,
                manualCookieHeader: fallbackCookieHeader)
            return ClaudeDebugLogConfiguration(
                runtime: CodexBarCore.ProviderRuntime.app,
                sourceMode: sourceMode,
                environment: environment,
                webExtrasEnabled: claudeSettings.webExtrasEnabled,
                usageDataSource: claudeSettings.usageDataSource,
                cookieSource: claudeSettings.cookieSource,
                cookieHeader: claudeSettings.manualCookieHeader ?? "",
                keepCLISessionsAlive: snapshot.debugKeepCLISessionsAlive)
        }
    }

    private struct ClaudeDebugExecutionContext {
        let interaction: ProviderInteraction
        let refreshPhase: ProviderRefreshPhase
        #if DEBUG
        let keychainServiceOverride: String?
        let credentialsURLOverride: URL?
        let testingOverrides: ClaudeOAuthCredentialsStore.TestingOverridesSnapshot
        let keychainDeniedUntilStoreOverride: ClaudeOAuthKeychainAccessGate.DeniedUntilStore?
        let keychainPromptModeOverride: ClaudeOAuthKeychainPromptMode?
        let keychainReadStrategyOverride: ClaudeOAuthKeychainReadStrategy?
        let cliPathOverride: String?
        let statusFetchOverride: ClaudeStatusProbe.FetchOverride?
        #endif

        func apply<T>(_ operation: () async -> T) async -> T {
            await ProviderInteractionContext.$current.withValue(self.interaction) {
                await ProviderRefreshContext.$current.withValue(self.refreshPhase) {
                    #if DEBUG
                    return await KeychainCacheStore.withServiceOverrideForTesting(self.keychainServiceOverride) {
                        await ClaudeOAuthCredentialsStore
                            .withCredentialsURLOverrideForTesting(self.credentialsURLOverride) {
                                await ClaudeOAuthCredentialsStore
                                    .withTestingOverridesSnapshotForTask(self.testingOverrides) {
                                        await ClaudeOAuthKeychainAccessGate
                                            .withDeniedUntilStoreOverrideForTesting(self
                                                .keychainDeniedUntilStoreOverride)
                                            {
                                                await ClaudeOAuthKeychainPromptPreference
                                                    .withTaskOverrideForTesting(self.keychainPromptModeOverride) {
                                                        await ClaudeOAuthKeychainReadStrategyPreference
                                                            .withTaskOverrideForTesting(self
                                                                .keychainReadStrategyOverride)
                                                            {
                                                                await ClaudeCLIResolver
                                                                    .withResolvedBinaryPathOverrideForTesting(self
                                                                        .cliPathOverride)
                                                                    {
                                                                        await ClaudeStatusProbe
                                                                            .withFetchOverrideForTesting(self
                                                                                .statusFetchOverride)
                                                                            {
                                                                                await operation()
                                                                            }
                                                                    }
                                                            }
                                                    }
                                            }
                                    }
                            }
                    }
                    #else
                    return await operation()
                    #endif
                }
            }
        }
    }

    private func currentClaudeDebugExecutionContext() -> ClaudeDebugExecutionContext {
        #if DEBUG
        ClaudeDebugExecutionContext(
            interaction: ProviderInteractionContext.current,
            refreshPhase: ProviderRefreshContext.current,
            keychainServiceOverride: KeychainCacheStore.currentServiceOverrideForTesting,
            credentialsURLOverride: ClaudeOAuthCredentialsStore.currentCredentialsURLOverrideForTesting,
            testingOverrides: ClaudeOAuthCredentialsStore.currentTestingOverridesSnapshotForTask,
            keychainDeniedUntilStoreOverride: ClaudeOAuthKeychainAccessGate.currentDeniedUntilStoreOverrideForTesting,
            keychainPromptModeOverride: ClaudeOAuthKeychainPromptPreference.currentTaskOverrideForTesting,
            keychainReadStrategyOverride: ClaudeOAuthKeychainReadStrategyPreference.currentTaskOverrideForTesting,
            cliPathOverride: ClaudeCLIResolver.currentResolvedBinaryPathOverrideForTesting,
            statusFetchOverride: ClaudeStatusProbe.currentFetchOverrideForTesting)
        #else
        ClaudeDebugExecutionContext(
            interaction: ProviderInteractionContext.current,
            refreshPhase: ProviderRefreshContext.current)
        #endif
    }

    private static func debugCursorLog(
        browserDetection: BrowserDetection,
        cursorCookieSource: ProviderCookieSource,
        cursorCookieHeader: String) async -> String
    {
        await runWithTimeout(seconds: 15) {
            var lines: [String] = []

            do {
                let probe = CursorStatusProbe(browserDetection: browserDetection)
                let snapshot: CursorStatusSnapshot = if cursorCookieSource == .manual,
                                                        let normalizedHeader = CookieHeaderNormalizer
                                                            .normalize(cursorCookieHeader)
                {
                    try await probe.fetchWithManualCookies(normalizedHeader)
                } else {
                    try await probe.fetch { msg in lines.append("[cursor-cookie] \(msg)") }
                }

                lines.append("")
                lines.append("Cursor Status Summary:")
                lines.append("membershipType=\(snapshot.membershipType ?? "nil")")
                lines.append("accountEmail=\(snapshot.accountEmail ?? "nil")")
                lines.append("planPercentUsed=\(snapshot.planPercentUsed)%")
                lines.append("planUsedUSD=$\(snapshot.planUsedUSD)")
                lines.append("planLimitUSD=$\(snapshot.planLimitUSD)")
                lines.append("onDemandUsedUSD=$\(snapshot.onDemandUsedUSD)")
                lines.append("onDemandLimitUSD=\(snapshot.onDemandLimitUSD.map { "$\($0)" } ?? "nil")")
                if let teamUsed = snapshot.teamOnDemandUsedUSD {
                    lines.append("teamOnDemandUsedUSD=$\(teamUsed)")
                }
                if let teamLimit = snapshot.teamOnDemandLimitUSD {
                    lines.append("teamOnDemandLimitUSD=$\(teamLimit)")
                }
                lines.append("billingCycleEnd=\(snapshot.billingCycleEnd?.description ?? "nil")")

                if let rawJSON = snapshot.rawJSON {
                    lines.append("")
                    lines.append("Raw API Response:")
                    lines.append(rawJSON)
                }

                return lines.joined(separator: "\n")
            } catch {
                lines.append("")
                lines.append("Cursor probe failed: \(error.localizedDescription)")
                return lines.joined(separator: "\n")
            }
        }
    }

    private static func debugAugmentLog() async -> String {
        await runWithTimeout(seconds: 15) {
            let probe = AugmentStatusProbe()
            return await probe.debugRawProbe()
        }
    }

    private static func debugAmpLog(
        browserDetection: BrowserDetection,
        ampCookieSource: ProviderCookieSource,
        ampCookieHeader: String) async -> String
    {
        await runWithTimeout(seconds: 15) {
            let fetcher = AmpUsageFetcher(browserDetection: browserDetection)
            let manualHeader = ampCookieSource == .manual
                ? CookieHeaderNormalizer.normalize(ampCookieHeader)
                : nil
            return await fetcher.debugRawProbe(cookieHeaderOverride: manualHeader)
        }
    }

    private static func debugOllamaLog(
        browserDetection: BrowserDetection,
        ollamaCookieSource: ProviderCookieSource,
        ollamaCookieHeader: String) async -> String
    {
        await runWithTimeout(seconds: 15) {
            let fetcher = OllamaUsageFetcher(browserDetection: browserDetection)
            let manualHeader = ollamaCookieSource == .manual
                ? CookieHeaderNormalizer.normalize(ollamaCookieHeader)
                : nil
            return await fetcher.debugRawProbe(
                cookieHeaderOverride: manualHeader,
                manualCookieMode: ollamaCookieSource == .manual)
        }
    }

    private func detectVersions() {
        let implementations = ProviderCatalog.all
        let browserDetection = self.browserDetection
        Task { @MainActor [weak self] in
            let resolved = await Task.detached { () -> [UsageProvider: String] in
                var resolved: [UsageProvider: String] = [:]
                await withTaskGroup(of: (UsageProvider, String?).self) { group in
                    for implementation in implementations {
                        let context = ProviderVersionContext(
                            provider: implementation.id,
                            browserDetection: browserDetection)
                        group.addTask {
                            await (implementation.id, implementation.detectVersion(context: context))
                        }
                    }
                    for await (provider, version) in group {
                        guard let version, !version.isEmpty else { continue }
                        resolved[provider] = version
                    }
                }
                return resolved
            }.value
            self?.versions = resolved
        }
    }

    @MainActor
    private func schedulePathDebugInfoRefresh() {
        self.pathDebugRefreshTask?.cancel()
        self.pathDebugRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            await self?.refreshPathDebugInfo()
        }
    }

    private func runBackgroundSnapshot(
        _ snapshot: @escaping @Sendable () async -> PathDebugSnapshot) async
    {
        let result = await snapshot()
        await MainActor.run {
            self.pathDebugInfo = result
        }
    }

    private func refreshPathDebugInfo() async {
        await self.runBackgroundSnapshot {
            await PathBuilder.debugSnapshotAsync(purposes: [.rpc, .tty, .nodeTooling])
        }
    }

    private func refreshTokenUsage(_ provider: UsageProvider, force: Bool) async {
        guard ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost else {
            self.tokenSnapshots.removeValue(forKey: provider)
            self.tokenErrors[provider] = nil
            self.tokenFailureGates[provider]?.reset()
            self.lastTokenFetchAt.removeValue(forKey: provider)
            self.lastTokenFetchScope.removeValue(forKey: provider)
            return
        }

        if Self.tokenCostRequiresProviderSnapshot(provider) {
            if let snapshot = self.tokenSnapshot(fromProviderSnapshot: self.snapshots[provider], provider: provider) {
                self.tokenSnapshots[provider] = snapshot
                self.tokenErrors[provider] = nil
                self.tokenFailureGates[provider]?.recordSuccess()
                self.persistWidgetSnapshot(reason: "token-usage")
            } else {
                self.tokenSnapshots.removeValue(forKey: provider)
                self.tokenErrors[provider] = nil
                self.tokenFailureGates[provider]?.reset()
            }
            return
        }

        guard self.settings.costUsageEnabled else {
            self.tokenSnapshots.removeValue(forKey: provider)
            self.tokenErrors[provider] = nil
            self.tokenFailureGates[provider]?.reset()
            self.lastTokenFetchAt.removeValue(forKey: provider)
            self.lastTokenFetchScope.removeValue(forKey: provider)
            return
        }

        guard self.isEnabled(provider) else {
            self.tokenSnapshots.removeValue(forKey: provider)
            self.tokenErrors[provider] = nil
            self.tokenFailureGates[provider]?.reset()
            self.lastTokenFetchAt.removeValue(forKey: provider)
            self.lastTokenFetchScope.removeValue(forKey: provider)
            return
        }

        guard !self.tokenRefreshInFlight.contains(provider) else { return }

        let now = Date()
        let historyDays = self.settings.costUsageHistoryDays
        let costScope = self.tokenCostScope(for: provider)
        let costScopeSignature = "\(costScope.signature)|historyDays=\(historyDays)"
        if !force,
           let last = self.lastTokenFetchAt[provider],
           self.lastTokenFetchScope[provider] == costScopeSignature,
           now.timeIntervalSince(last) < self.tokenFetchTTL
        {
            return
        }
        self.lastTokenFetchAt[provider] = now
        self.lastTokenFetchScope[provider] = costScopeSignature
        self.tokenRefreshInFlight.insert(provider)
        defer { self.tokenRefreshInFlight.remove(provider) }

        if let override = self._test_tokenUsageRefreshOverride {
            await override(provider, force)
            if Task.isCancelled {
                self.lastTokenFetchAt.removeValue(forKey: provider)
                self.lastTokenFetchScope.removeValue(forKey: provider)
            }
            return
        }

        let startedAt = Date()
        let providerText = provider.rawValue
        self.tokenCostLogger
            .debug("cost usage start provider=\(providerText) force=\(force)")

        do {
            let fetcher = self.costUsageFetcher
            let timeoutSeconds = self.tokenFetchTimeout
            let environment = provider == .bedrock
                ? ProviderRegistry.makeEnvironment(
                    base: self.environmentBase,
                    provider: provider,
                    settings: self.settings,
                    tokenOverride: nil)
                : self.environmentBase
            // Codex cost usage scans local session logs from this machine. That data is
            // intentionally presented as provider-level local telemetry rather than managed-account
            // remote state, so managed Codex account selection does not retarget that fetch.
            // If the UI later needs account-scoped token history, it should label and source that
            // separately instead of silently changing the meaning of this section.
            let snapshot = try await withThrowingTaskGroup(of: CostUsageTokenSnapshot.self) { group in
                group.addTask(priority: .utility) {
                    try await fetcher.loadTokenSnapshot(
                        provider: provider,
                        environment: environment,
                        now: now,
                        forceRefresh: force,
                        allowVertexClaudeFallback: !self.isEnabled(.claude),
                        codexHomePath: costScope.codexHomePath,
                        historyDays: historyDays)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    throw CostUsageError.timedOut(seconds: Int(timeoutSeconds))
                }
                defer { group.cancelAll() }
                guard let snapshot = try await group.next() else { throw CancellationError() }
                return snapshot
            }
            try Task.checkCancellation()

            guard !snapshot.daily.isEmpty else {
                self.tokenSnapshots.removeValue(forKey: provider)
                self.tokenErrors[provider] = Self.tokenCostNoDataMessage(for: provider)
                self.tokenFailureGates[provider]?.recordSuccess()
                return
            }
            let duration = Date().timeIntervalSince(startedAt)
            let sessionCost = snapshot.sessionCostUSD
                .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
            let monthCost = snapshot.last30DaysCostUSD
                .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
            let durationText = String(format: "%.2f", duration)
            let message =
                "cost usage success provider=\(providerText) " +
                "duration=\(durationText)s " +
                "today=\(sessionCost) " +
                "historyDays=\(historyDays) windowCost=\(monthCost)"
            self.tokenCostLogger.info(message)
            self.tokenSnapshots[provider] = snapshot
            self.tokenErrors[provider] = nil
            self.tokenFailureGates[provider]?.recordSuccess()
            self.persistWidgetSnapshot(reason: "token-usage")
        } catch {
            if error is CancellationError {
                self.lastTokenFetchAt.removeValue(forKey: provider)
                self.lastTokenFetchScope.removeValue(forKey: provider)
                return
            }
            let duration = Date().timeIntervalSince(startedAt)
            let msg = error.localizedDescription
            let durationText = String(format: "%.2f", duration)
            let message = "cost usage failed provider=\(providerText) duration=\(durationText)s error=\(msg)"
            self.tokenCostLogger.error(message)
            let hadPriorData = self.tokenSnapshots[provider] != nil
            let shouldSurface = self.tokenFailureGates[provider]?
                .shouldSurfaceError(onFailureWithPriorData: hadPriorData) ?? true
            if shouldSurface {
                self.tokenErrors[provider] = error.localizedDescription
                self.tokenSnapshots.removeValue(forKey: provider)
            } else {
                self.tokenErrors[provider] = nil
            }
        }
    }
}
