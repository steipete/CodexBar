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
        _ = self.diagnostics
        _ = self.knownLimitsAvailabilityByProvider
        _ = self.lastSourceLabels
        _ = self.lastFetchAttempts
        _ = (self.accountSnapshots, self.tokenAccountLiveStateProviders, self.codexAccountSnapshots)
        _ = self.kiloScopeSnapshots
        _ = self.claudeSwapAccountSnapshots
        _ = self.claudeSwapLastError
        _ = self.claudeSwapRevision
        _ = self.tokenSnapshots
        _ = self.tokenSnapshotPublications
        _ = self.tokenErrors
        _ = self.tokenRefreshInFlight
        _ = self.codexCostCatchUpActivity
        _ = self.credits
        _ = self.lastCreditsError
        _ = self.openAIDashboard
        _ = self.lastOpenAIDashboardError
        _ = self.openAIDashboardRequiresLogin
        _ = self.openAIDashboardAttachmentRevision
        _ = self.versions
        _ = self.isRefreshing
        _ = self.hasForcedRefreshEnrichmentInFlight
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
        _ = self.claudeSwapAccountSnapshots
        _ = self.claudeSwapRevision
        _ = self.errors
        _ = self.diagnostics
        _ = self.knownLimitsAvailabilityByProvider
        _ = self.credits
        _ = self.lastCreditsError
        _ = self.openAIDashboard
        _ = self.lastOpenAIDashboardError
        _ = self.openAIDashboardRequiresLogin
        _ = self.refreshingProviders
        _ = self.statuses
        _ = self.tokenSnapshotPublications
        _ = self.spendDashboardTokenPublications
        _ = self.spendDashboardPublication.revision
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
                let enabledNow = Set(self.settings.enabledProvidersOrdered(
                    metadataByProvider: self.providerMetadata))
                if enabledNow != self.versionDetectionProviders {
                    self.detectVersions()
                }
                await self.refreshHistoricalDatasetIfNeeded()
                await self.refreshForSettingsChange()
            }
        }
    }

    var backgroundWorkSettingsObservationToken: Int {
        _ = self.settings.backgroundWorkSettingsRevision
        return 0
    }

    var attachedOpenAIDashboardSnapshot: OpenAIDashboardSnapshot? {
        guard self.openAIDashboardAttachmentAuthorized else { return nil }
        return self.openAIDashboard
    }

    private static func isRunningTestsProcess() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let testKeys = ["XCTestConfigurationFilePath", "XCTestSessionIdentifier", "SWIFT_TESTING_ENABLED"]
        return testKeys.contains(where: { environment[$0] != nil }) || CommandLine.arguments.contains { argument in
            argument.contains("xctest") || argument.contains("swift-testing")
        }
    }

    /// Returns the login method (plan type) for the specified provider, if available.
    private func loginMethod(for provider: UsageProvider) -> String? {
        self.snapshots[provider.instanceID]?.loginMethod(for: provider)
    }

    /// Returns true if the Claude account appears to be a subscription (Max, Pro, Ultra, Team).
    /// Returns false for API users or when plan cannot be determined.
    func isClaudeSubscription() -> Bool {
        // Provider-specific by design: Claude subscription plans choose its consumer dashboard account action.
        Self.isSubscriptionPlan(self.loginMethod(for: .claude))
    }

    /// Determines if a login method string indicates a Claude subscription plan.
    /// Known subscription indicators: Max, Pro, Ultra, Team (case-insensitive).
    nonisolated static func isSubscriptionPlan(_ loginMethod: String?) -> Bool {
        ClaudePlan.isSubscriptionLoginMethod(loginMethod)
    }

    var preferredSnapshot: UsageSnapshot? {
        for provider in self.enabledProviders() {
            if let snap = self.snapshots[provider] {
                return snap
            }
        }
        return nil
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

    var snapshots: [ProviderInstanceID: UsageSnapshot] = [:]
    var errors: [ProviderInstanceID: String] = [:]
    var diagnostics: [ProviderInstanceID: String] = [:]
    var geminiObservedConsumerTierDeprecation = false
    var knownLimitsAvailabilityByProvider: [ProviderInstanceID: UsageLimitsAvailability] = [:]
    var lastSourceLabels: [ProviderInstanceID: String] = [:]
    var lastFetchAttempts: [ProviderInstanceID: [ProviderFetchAttempt]] = [:]
    var accountSnapshots: [ProviderInstanceID: [TokenAccountUsageSnapshot]] = [:]
    var tokenAccountLiveStateProviders: Set<ProviderInstanceID> = []
    var codexAccountSnapshots: [CodexAccountUsageSnapshot] = []
    var kiloScopeSnapshots: [KiloScopeSnapshot] = []
    var claudeSwapAccountSnapshots: [ProviderAccountUsageSnapshot] = []
    var claudeSwapLastRefreshAt: Date?
    var claudeSwapLastError: String?
    var claudeSwapDetectedVersion: String?
    var claudeSwapRevision: UInt64 = 0
    @ObservationIgnored var claudeSwapRefreshTask: Task<Void, Never>?
    @ObservationIgnored var claudeSwapTransientState = ClaudeSwapTransientState()
    var tokenSnapshots: [ProviderInstanceID: CostUsageTokenSnapshot] = [:]
    var tokenSnapshotPublications: [ProviderInstanceID: TokenSnapshotPublication] = [:]
    var tokenSnapshotPublicationRevisions: [ProviderInstanceID: UInt64] = [:]
    var spendDashboardTokenPublications: [ProviderInstanceID: TokenSnapshotPublication] = [:]
    var spendDashboardTokenPublicationRevisions: [ProviderInstanceID: UInt64] = [:]
    var spendDashboardPublication = SpendDashboardPublication.empty
    @ObservationIgnored var sharedSpendDashboardControllerStorage: SpendDashboardController?
    @ObservationIgnored var sharedSpendDashboardObservationStarted = false
    var tokenErrors: [ProviderInstanceID: String] = [:]
    var tokenRefreshInFlight: Set<ProviderInstanceID> = []
    var codexCostCatchUpActivity: CodexCostCatchUpActivity?
    var spendDashboardCodexCostCatchUpActivity: CodexCostCatchUpActivity?
    var spendDashboardCodexCostCatchUpRevision: UInt64 = 0
    var credits: CreditsSnapshot?
    var lastCreditsError: String?
    var openAIDashboard: OpenAIDashboardSnapshot?
    var lastOpenAIDashboardError: String?
    var openAIDashboardRequiresLogin: Bool = false
    var openAIDashboardCookieImportStatus: String?
    var openAIDashboardCookieImportDebugLog: String?
    var versions: [ProviderInstanceID: String] = [:]
    @ObservationIgnored var versionDetectionProviders: Set<ProviderInstanceID> = []
    @ObservationIgnored private(set) var versionDetectionTask: Task<Void, Never>?
    @ObservationIgnored var claudeVersionRefreshTask: Task<Void, Never>?
    var isRefreshing = false
    var hasForcedRefreshEnrichmentInFlight = false
    var refreshingProviders: Set<ProviderInstanceID> = []
    var debugForceAnimation = false
    var pathDebugInfo: PathDebugSnapshot = .empty
    var statuses: [ProviderInstanceID: ProviderStatus] = [:]
    var statusComponents: [ProviderInstanceID: [ProviderStatusComponent]] = [:]
    var probeLogs: [ProviderInstanceID: String] = [:]
    var historicalPaceRevision: Int = 0
    var planUtilizationHistoryRevision: Int = 0
    var providerStorageFootprints: [ProviderInstanceID: ProviderStorageFootprint] = [:]
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
    @ObservationIgnored var lastOpenAIDashboardPageScrapeAt: Date?
    @ObservationIgnored var lastOpenAIDashboardCookieImportAttemptAt: Date?
    @ObservationIgnored var lastOpenAIDashboardCookieImportEmail: String?
    @ObservationIgnored var lastCodexAccountScopedRefreshGuard: CodexAccountScopedRefreshGuard?
    @ObservationIgnored var lastCodexUsagePublicationGuard: CodexAccountScopedRefreshGuard?
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
    @ObservationIgnored var _test_providerFetchOutcomeOverride: (@MainActor (
        UsageProvider) async -> ProviderFetchOutcome)?
    @ObservationIgnored var _test_tokenUsageRefreshOverride: (@MainActor (UsageProvider, Bool) async -> Void)?
    @ObservationIgnored var _test_tokenRefreshSequenceStartBarrier: (@MainActor () async -> Void)?
    @ObservationIgnored var _test_tokenUsageSnapshotLoaderOverride: (@MainActor (
        UsageProvider,
        Bool,
        Date,
        String?,
        Int) async throws -> CostUsageTokenSnapshot)?
    @ObservationIgnored var _test_cachedCodexTokenSnapshotLoaderOverride: (@MainActor (
        Date,
        String?,
        Int) async -> (
        snapshot: CostUsageTokenSnapshot,
        lastRefreshAt: Date?,
        staleSnapshotUpdatedAt: Date?)?)?
    @ObservationIgnored var _test_codexCostCatchUpStatusOverride: (@MainActor (
        String?) async -> CostUsageFetcher.CodexScanCatchUpStatus)?
    @ObservationIgnored var _test_codexCostCatchUpAdvanceOverride: (@MainActor (
        Date,
        String?,
        Int) async throws -> CostUsageFetcher.CodexScanCatchUpStatus)?
    @ObservationIgnored var _test_codexCostCatchUpSleepOverride: (@MainActor (
        TimeInterval) async throws -> Void)?
    @ObservationIgnored var _test_codexCostCatchUpResourceStateOverride: (@MainActor () -> (
        powerSource: CodexCostCatchUpPowerSource,
        lowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState))?
    @ObservationIgnored var _test_spendDashboardCodexCostCatchUpStatusOverride: (@MainActor (
        CodexSpendScanRequest) async -> CostUsageFetcher.CodexScanCatchUpStatus)?
    @ObservationIgnored var _test_spendDashboardCodexCostCatchUpAdvanceOverride: (@MainActor (
        CodexSpendScanRequest,
        Date,
        Int) async throws -> CostUsageFetcher.CodexScanCatchUpStatus)?
    @ObservationIgnored var _test_spendDashboardCodexCostCatchUpSleepOverride: (@MainActor (
        TimeInterval) async throws -> Void)?
    @ObservationIgnored var _test_spendDashboardCodexCostCatchUpResourceStateOverride: (@MainActor () -> (
        powerSource: CodexCostCatchUpPowerSource,
        lowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState))?
    @ObservationIgnored var _test_providerStatusFetchOverride: (@MainActor (
        UsageProvider) async throws -> ProviderStatus)?
    @ObservationIgnored var _test_forcedRefreshEnrichmentWaitObserver: (@MainActor () -> Void)?
    @ObservationIgnored var _test_startupConnectivityRetryScheduled: (@MainActor (Int, TimeInterval) -> Void)?
    @ObservationIgnored var _test_startupConnectivityRetrySleepOverride: (@MainActor (
        TimeInterval) async throws -> Void)?
    @ObservationIgnored var widgetSnapshotPersistTask: Task<Void, Never>?
    @ObservationIgnored var lastQueuedWidgetSnapshot: WidgetSnapshot?
    @ObservationIgnored let widgetSnapshotURL: URL?
    @ObservationIgnored var widgetUsagePreservationBlockedProviders: Set<ProviderInstanceID> = []

    @ObservationIgnored let codexFetcher: UsageFetcher
    @ObservationIgnored let claudeFetcher: any ClaudeUsageFetching
    @ObservationIgnored let costUsageFetcher: CostUsageFetcher
    @ObservationIgnored let browserDetection: BrowserDetection
    @ObservationIgnored private let registry: ProviderRegistry
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let environmentBase: [String: String]
    @ObservationIgnored let pluginApprovalStore = ProviderPluginApprovalStore()
    @ObservationIgnored let sessionQuotaNotifier: any SessionQuotaNotifying
    @ObservationIgnored let sessionQuotaLogger = CodexBarLog.logger(LogCategories.sessionQuota)
    // Provider-specific by design: OpenAI web and Augment runtime diagnostics have dedicated app-owned log streams.
    @ObservationIgnored let openAIWebLogger = CodexBarLog.logger(LogCategories.provider(.openai, scope: "web"))
    @ObservationIgnored private let tokenCostLogger = CodexBarLog.logger(LogCategories.tokenCost)
    @ObservationIgnored let augmentLogger = CodexBarLog.logger(LogCategories.provider(.augment))
    @ObservationIgnored let providerLogger = CodexBarLog.logger(LogCategories.providers)
    @ObservationIgnored let adaptiveRefreshLogger = CodexBarLog.logger(LogCategories.adaptiveRefresh)
    @ObservationIgnored var openAIWebDebugLines: [String] = []
    @ObservationIgnored var failureGates: [ProviderInstanceID: ConsecutiveFailureGate] = [:]
    @ObservationIgnored var tokenFailureGates: [ProviderInstanceID: ConsecutiveFailureGate] = [:]
    @ObservationIgnored var providerSpecs: [UsageProvider: ProviderSpec] = [:]
    @ObservationIgnored let providerMetadata: [UsageProvider: ProviderMetadata]
    @ObservationIgnored var providerRuntimes: [ProviderInstanceID: any ProviderRuntime] = [:]
    @ObservationIgnored var providerRefreshCoordinator = ProviderRefreshCoordinator<ProviderInstanceID>()
    @ObservationIgnored var providerRefreshPublicationContexts:
        [ProviderInstanceID: ProviderRefreshPublicationContext] = [:]
    @ObservationIgnored var providerCleanupRevisions: [ProviderInstanceID: UInt64] = [:]
    @ObservationIgnored private var providerAvailabilityCache:
        [ProviderInstanceID: ProviderAvailabilityCacheEntry] = [:]
    @ObservationIgnored var accountInfoCache: [ProviderInstanceID: AccountInfoCacheEntry] = [:]
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    /// In-memory only; resets on every launch.
    @ObservationIgnored private(set) var lastMenuOpenAt: Date?
    /// Latest local Codex/Claude transcript activity observed by the existing session scanner.
    /// In-memory only; paths and session identities never enter the refresh policy.
    @ObservationIgnored private(set) var lastCodingActivityAt: Date?
    @ObservationIgnored var adaptiveRefreshScheduledAt: Date?
    @ObservationIgnored var tokenRefreshSequenceTask: Task<Void, Never>?
    @ObservationIgnored var tokenRefreshSequenceToken: UUID?
    @ObservationIgnored var tokenRefreshSequenceProvider: ProviderInstanceID?
    @ObservationIgnored var tokenRefreshSequenceIsForcedAllPass = false
    @ObservationIgnored var pendingForcedTokenRefresh = false
    @ObservationIgnored var lastForcedTokenRefreshStartedAt: Date?
    @ObservationIgnored var tokenRefreshRetryProviders: Set<ProviderInstanceID> = []
    @ObservationIgnored var codexCostCatchUpTask: Task<Void, Never>?
    @ObservationIgnored var codexCostCatchUpToken: UUID?
    @ObservationIgnored var codexCostCatchUpScopeSignature: String?
    @ObservationIgnored var codexCostCatchUpMode: CodexCostCatchUpMode = .automatic
    @ObservationIgnored var codexCostCatchUpStopRequested = false
    @ObservationIgnored var codexCostCatchUpPassIsRunning = false
    @ObservationIgnored var codexCostCatchUpRestartRequested = false
    @ObservationIgnored var spendDashboardCodexCostCatchUpTask: Task<Void, Never>?
    @ObservationIgnored var spendDashboardCodexCostCatchUpToken: UUID?
    @ObservationIgnored var spendDashboardCodexCostCatchUpScopeSignature: String?
    @ObservationIgnored var spendDashboardCodexCostCatchUpMode: CodexCostCatchUpMode = .automatic
    @ObservationIgnored var spendDashboardCodexCostCatchUpStopRequested = false
    @ObservationIgnored var spendDashboardCodexCostCatchUpPassIsRunning = false
    @ObservationIgnored var spendDashboardCodexCostCatchUpRestartRequested = false
    @ObservationIgnored var forcedRefreshEnrichmentTask: Task<Void, Never>?
    @ObservationIgnored var forcedRefreshEnrichmentToken: UUID?
    @ObservationIgnored var pendingForcedRefreshEnrichmentTask: Task<Void, Never>?
    @ObservationIgnored var pendingForcedRefreshEnrichmentToken: UUID?
    @ObservationIgnored var forcedRefreshEnrichmentGeneration: UInt64 = 0
    @ObservationIgnored var requiredRefreshTask: Task<Bool, Never>?
    @ObservationIgnored var requiredRefreshTaskToken: UUID?
    @ObservationIgnored var pendingRequiredRefreshRequest: RequiredRefreshRequest?
    @ObservationIgnored var requiredRefreshRequestGeneration: UInt64 = 0
    @ObservationIgnored var requiredRefreshCompletedGeneration: UInt64 = 0
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
    @ObservationIgnored var lastKnownResetSnapshots: [ProviderInstanceID: UsageSnapshot] = [:]
    /// A stable ambient Auto refresh failed after every live Claude source was exhausted, so persisted
    /// plan-utilization history may safely supply a stale presentation snapshot for the same profile.
    @ObservationIgnored var claudeHistoryFallbackEligible = false
    @ObservationIgnored var deepseekProfileTransition: DeepSeekProfileTransition?
    @ObservationIgnored var sessionQuotaTransitionStates: [ProviderInstanceID: SessionQuotaTransitionState] = [:]
    @ObservationIgnored var codexSessionQuotaBaselineRequirement: CodexSessionQuotaBaselineRequirement?
    var codexSessionQuotaBaselineRequired: Bool {
        self.codexSessionQuotaBaselineRequirement != nil
    }

    @ObservationIgnored var quotaWarningState: [QuotaWarningStateKey: QuotaWarningState] = [:]
    @ObservationIgnored let hookRateLimiter = HookRateLimiter()
    @ObservationIgnored var providerStatusHadIssue: [ProviderInstanceID: Bool] = [:]
    /// Last observed usage fraction (0...1) per account and quota-warning lane, used
    /// to detect upward crossings of a quota_low hook rule's own threshold.
    @ObservationIgnored var quotaLowHookUsage: [QuotaWarningStateKey: Double] = [:]
    @ObservationIgnored var quotaLowHookConfigRevision: Int?
    @ObservationIgnored var predictivePaceWarningNotifiedKeys: Set<PredictivePaceWarningStateKey> = []
    @ObservationIgnored var lastPermissionPromptNotificationAt: [ProviderInstanceID: Date] = [:]
    @ObservationIgnored var lastTokenFetchAt: [ProviderInstanceID: Date] = [:]
    @ObservationIgnored var lastTokenFetchScope: [ProviderInstanceID: String] = [:]
    @ObservationIgnored var lastSpendDashboardTokenFetchAt: [ProviderInstanceID: Date] = [:]
    @ObservationIgnored var lastSpendDashboardTokenFetchScope: [ProviderInstanceID: String] = [:]
    @ObservationIgnored var spendDashboardTokenRefreshInFlight: Set<ProviderInstanceID> = []
    @ObservationIgnored var planUtilizationHistory: [ProviderInstanceID: PlanUtilizationHistoryBuckets] = [:]
    @ObservationIgnored var sessionEquivalentBurnCache: [ProviderInstanceID: SessionEquivalentBurnCacheEntry] = [:]
    @ObservationIgnored var sessionEquivalentHistoryScanCount: Int = 0

    /// Background load task; cleared on deinit and on the cancel test seam.
    @ObservationIgnored var planUtilizationHistoryLoadTask: Task<Void, Never>?
    /// Set once after the load completes. Gates mutation paths and sync menu
    /// accessors so they cannot race the decode or write empty history back to disk.
    @ObservationIgnored var planUtilizationHistoryLoaded: Bool = false
    @ObservationIgnored var sessionLimitResetDetectorStates: [String: LimitResetDetectorState] = [:]
    @ObservationIgnored var weeklyLimitResetDetectorStates: [String: LimitResetDetectorState] = [:]
    @ObservationIgnored private var hasCompletedInitialRefresh: Bool = false
    @ObservationIgnored private let providerAvailabilityCacheTTL: TimeInterval = 1
    @ObservationIgnored let accountInfoCacheTTL: TimeInterval = 30
    /// Energy/WidgetKit floor for expensive local-history scans and their additional snapshot publications.
    /// Faster provider refreshes still update quota/status normally, but reuse token-cost history within this TTL.
    static let minimumTokenFetchTTL: TimeInterval = 15 * 60

    var tokenFetchTTL: TimeInterval? {
        Self.tokenFetchTTL(
            for: self.settings.refreshFrequency,
            lowPowerModeEnabled: self.settings.backgroundWorkLowPowerModeEnabled)
    }

    static func tokenFetchTTL(
        for frequency: RefreshFrequency,
        lowPowerModeEnabled: Bool = false) -> TimeInterval?
    {
        let interval = frequency.usesAdaptivePolicy
            ? AdaptiveRefreshPolicy.nominalIntervalForHeuristics
            : frequency.seconds
        let widgetSafeInterval = interval.map { max($0, Self.minimumTokenFetchTTL) }
        return BackgroundWorkPowerPolicy.automaticInterval(
            widgetSafeInterval,
            lowPowerModeEnabled: lowPowerModeEnabled)
    }

    @ObservationIgnored let tokenFetchTimeout: TimeInterval = 10 * 60
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
        planUtilizationHistoryStore: PlanUtilizationHistoryStore? = nil,
        codexAccountUsageSnapshotStore: (any CodexAccountUsageSnapshotStoring)? = nil,
        sessionQuotaNotifier: any SessionQuotaNotifying = SessionQuotaNotifier(),
        startupBehavior: StartupBehavior = .automatic,
        environmentBase: [String: String] = ProcessInfo.processInfo.environment,
        widgetSnapshotURL: URL? = nil,
        planUtilizationHistoryLoadGateForTesting: PlanUtilizationHistoryLoadGate? = nil)
    {
        self.codexFetcher = fetcher
        self.browserDetection = browserDetection
        self.claudeFetcher = claudeFetcher ?? ClaudeUsageFetcher(browserDetection: browserDetection)
        self.costUsageFetcher = costUsageFetcher
        self.settings = settings
        self.registry = registry
        self.environmentBase = environmentBase
        self.widgetSnapshotURL = widgetSnapshotURL
        self.historicalUsageHistoryStore = historicalUsageHistoryStore
        self.startupBehavior = startupBehavior.resolved(isRunningTests: Self.isRunningTestsProcess())
        let planHistoryStore = Self.resolvedPlanHistoryStore(planUtilizationHistoryStore, startup: self.startupBehavior)
        self.planUtilizationHistoryStore = planHistoryStore
        self.sessionQuotaNotifier = sessionQuotaNotifier
        self.codexAccountUsageSnapshotStore = codexAccountUsageSnapshotStore ??
            (self.startupBehavior.automaticallyStartsBackgroundWork ? FileCodexAccountUsageSnapshotStore() : nil)
        self.planUtilizationPersistenceCoordinator = PlanUtilizationHistoryPersistenceCoordinator(
            store: planHistoryStore)
        self.providerMetadata = registry.metadata
        self
            .failureGates = Dictionary(
                uniqueKeysWithValues: UsageProvider.allCases
                    .map { ($0.instanceID, ConsecutiveFailureGate()) })
        self.tokenFailureGates = Dictionary(
            uniqueKeysWithValues: UsageProvider.allCases
                .map { ($0.instanceID, ConsecutiveFailureGate()) })
        self.providerSpecs = registry.specs(
            settings: settings,
            metadata: self.providerMetadata,
            codexFetcher: fetcher,
            claudeFetcher: self.claudeFetcher,
            browserDetection: browserDetection,
            environmentBase: environmentBase)
        self.providerRuntimes = Dictionary(uniqueKeysWithValues: ProviderCatalog.all.compactMap { implementation in
            implementation.makeRuntime().map { (implementation.id.instanceID, $0) }
        })
        self.startPlanUtilizationHistoryLoad(
            gate: planUtilizationHistoryLoadGateForTesting,
            enabled: self.startupBehavior.automaticallyStartsBackgroundWork)
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
        self.startSharedSpendDashboardPublication()
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
        Task { await self.refresh(enrichmentMode: .automatic) }
        self.startTimer()
    }

    var iconStyle: IconStyle {
        let enabled = self.enabledProviders()
        if enabled.count > 1 {
            return .combined
        }
        if let provider = enabled.first?.firstPartyProvider {
            return self.style(for: provider)
        }
        // Provider-specific by design: Codex is the historical empty-enabled-set icon fallback.
        return .codex
    }

    var isStale: Bool {
        for provider in self.enabledProviders() where self.errors[provider] != nil {
            return true
        }
        return false
    }

    func enabledProviders() -> [ProviderInstanceID] {
        // Use cached enablement to avoid repeated UserDefaults lookups in animation ticks.
        let enabled = self.settings.enabledProvidersOrdered(metadataByProvider: self.providerMetadata)
        let now = Date()
        return enabled.filter { self.isEnabledProviderInstance($0, now: now) }
    }

    /// Enabled providers without availability filtering. Used for display (switcher, merge-icons).
    func enabledProvidersForDisplay() -> [ProviderInstanceID] {
        self.settings.enabledProvidersOrdered(metadataByProvider: self.providerMetadata)
    }

    /// Providers that should actually participate in background refresh/status/token work.
    func enabledProvidersForBackgroundWork() -> [ProviderInstanceID] {
        self.enabledProviders()
    }

    func metadata(for provider: UsageProvider) -> ProviderMetadata {
        self.providerMetadata[provider]!
    }

    var codexBrowserCookieOrder: BrowserCookieImportOrder {
        self.metadata(for: .codex).browserCookieOrder ?? Browser.defaultImportOrder
    }

    func snapshot(for instanceID: ProviderInstanceID) -> UsageSnapshot? {
        self.snapshots[instanceID]
    }

    /// The snapshot the menu-bar indicator should render for a provider instance.
    /// When the claude-swap adapter owns Claude account presentation, the active
    /// account's snapshot drives the bar so the indicator agrees with the account
    /// cards shown in the menu; the ambient provider snapshot remains the fallback
    /// whenever the adapter is disabled, below its presentation threshold, or the
    /// active account has no usable usage windows.
    func menuBarSnapshot(for instanceID: ProviderInstanceID) -> UsageSnapshot? {
        // Provider-specific by design: claude-swap adapter owns Claude menu-bar presentation; see #2731.
        self.claudeSwapMenuBarSnapshotOverride(for: instanceID) ?? self.snapshot(for: instanceID)
    }

    func sourceLabel(for provider: UsageProvider) -> String {
        var label = self.lastSourceLabels[provider.instanceID] ?? ""
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
        self.lastFetchAttempts[provider.instanceID] ?? []
    }

    func style(for provider: UsageProvider) -> IconStyle {
        self.providerSpecs[provider]?.style ?? .codex
    }

    func isStale(provider: UsageProvider) -> Bool {
        self.errors[provider.instanceID] != nil
    }

    func knownLimitsAvailability(for provider: UsageProvider) -> UsageLimitsAvailability? {
        self.knownLimitsAvailabilityByProvider[provider.instanceID]
    }

    func hasSatisfiedUsageFetch(for provider: UsageProvider) -> Bool {
        self.snapshot(for: provider.instanceID) != nil ||
            self.knownLimitsAvailability(for: provider)?.isUnavailable == true
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

    func isProviderAvailable(_ provider: UsageProvider, now: Date) -> Bool {
        guard provider != .codex else { return true }

        let configRevision = self.settings.configRevision
        if let cached = self.providerAvailabilityCache[provider.instanceID],
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
        self.providerAvailabilityCache[provider.instanceID] = ProviderAvailabilityCacheEntry(
            available: available,
            configRevision: configRevision,
            expiresAt: now.addingTimeInterval(self.providerAvailabilityCacheTTL))
        return available
    }

    private func invalidateProviderAvailabilityCache() {
        self.providerAvailabilityCache.removeAll(keepingCapacity: true)
    }

    #if DEBUG
    @ObservationIgnored private(set) var completedRefreshCountForTesting = 0
    #endif

    @discardableResult
    func runRefresh(
        enrichmentMode: RefreshEnrichmentMode = .automatic,
        startupConnectivityRetryAttempt: Int?,
        coalesceProviderRefreshesOverride: Bool? = nil,
        waitForRefreshAvailability: Bool = false) async -> Bool
    {
        if enrichmentMode == .automatic, waitForRefreshAvailability {
            return await self.enqueueRequiredRefresh(
                startupConnectivityRetryAttempt: startupConnectivityRetryAttempt,
                coalesceProviderRefreshesOverride: coalesceProviderRefreshesOverride)
        }

        guard !self.isRefreshing else { return false }
        guard enrichmentMode != .automatic || !self.hasForcedRefreshEnrichmentInFlight else { return false }
        let forcedBackgroundGeneration: UInt64?
        if enrichmentMode == .forcedBackground {
            self.forcedRefreshEnrichmentGeneration &+= 1
            forcedBackgroundGeneration = self.forcedRefreshEnrichmentGeneration
        } else {
            forcedBackgroundGeneration = nil
        }
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

        let completedRefresh = await ProviderRefreshContext.$current.withValue(refreshPhase) {
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
            self.scheduleStorageFootprintRefresh(for: displayEnabledProviders.compactMap(\.firstPartyProvider))

            await withTaskGroup(of: Void.self) { group in
                for instanceID in refreshProviders {
                    guard let provider = instanceID.firstPartyProvider else {
                        group.addTask { await self.refreshUserPlugin(instanceID) }
                        continue
                    }
                    group.addTask {
                        await self.refreshProvider(
                            provider,
                            coalesceIfRefreshing: coalesceProviderRefreshesOverride ??
                                (ProviderInteractionContext.current == .background))
                    }
                    if availableRefreshProviders.contains(provider.instanceID) {
                        group.addTask { await self.refreshProviderStatus(provider) }
                    }
                }
                if enrichmentMode == .forcedForeground {
                    group.addTask { await self.refreshCreditsNow(minimumSnapshotUpdatedAt: refreshStartedAt) }
                }
            }
            guard !Task.isCancelled else { return false }

            if enrichmentMode == .automatic {
                self.scheduleCreditsRefreshIfNeeded(minimumSnapshotUpdatedAt: refreshStartedAt)
            }

            if enrichmentMode == .forcedForeground {
                await self.refreshTokenUsageSequenceNow(force: true)
            } else if enrichmentMode == .automatic {
                // Token-cost usage can be slow; run it outside regular/menu-open refreshes so we don't block UI.
                self.scheduleTokenRefresh()
            }

            // OpenAI web scrape depends on the current Codex account email (which can change after login/account
            // switch). Run this after Codex usage refresh so we don't accidentally scrape with stale credentials.
            if enrichmentMode == .forcedBackground {
                // Account ownership must fail closed before the responsive foreground pass returns;
                // only the expensive dashboard fetch belongs in the deferred enrichment tail.
                self.syncOpenAIWebState()
            } else {
                await self.refreshOpenAIWebAfterProviderRefresh(
                    force: enrichmentMode == .forcedForeground,
                    refreshPhase: openAIWebRefreshPhase)
            }

            if enrichmentMode == .forcedForeground, self.openAIDashboardRequiresLogin {
                // Provider-specific by design: failed OpenAI attachment retries Codex usage before credits enrichment.
                await self.refreshProvider(.codex)
                await self.refreshCreditsNow(minimumSnapshotUpdatedAt: refreshStartedAt)
            }

            self.persistWidgetSnapshot(reason: "refresh")
            if let forcedBackgroundGeneration {
                self.enqueueForcedRefreshEnrichment(
                    generation: forcedBackgroundGeneration,
                    refreshStartedAt: refreshStartedAt,
                    openAIWebRefreshPhase: openAIWebRefreshPhase)
            }
            return true
        }

        guard completedRefresh else { return false }

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
        return true
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
    @ObservationIgnored private(set) var fixedRefreshIntervalForTesting: TimeInterval?
    @ObservationIgnored var adaptiveRefreshComputedIntervalForTesting: TimeInterval?

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
        #if DEBUG
        self.fixedRefreshIntervalForTesting = nil
        self.adaptiveRefreshComputedIntervalForTesting = nil
        #endif
        if !preservingResetBoundaryRefresh {
            self.cancelResetBoundaryRefresh()
        }

        let frequency = self.settings.refreshFrequency
        guard frequency != .manual else { return }

        if frequency.usesAdaptivePolicy {
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
                    await self?.refresh(enrichmentMode: .automatic)
                }
            }
            return
        }

        guard let wait = Self.effectiveAutomaticRefreshInterval(
            frequency.seconds,
            lowPowerModeEnabled: self.settings.backgroundWorkLowPowerModeEnabled)
        else { return }
        #if DEBUG
        self.fixedRefreshIntervalForTesting = wait
        let fixedTimerSleepOverride = self.refreshTimerSleepOverrideForTesting
        #else
        let fixedTimerSleepOverride: Duration? = nil
        #endif

        // Background poller so the menu stays responsive; canceled when settings change or store deallocates.
        // Fixed cadence is anchored to the scheduled tick time, not refresh completion, so slow provider
        // work doesn't permanently stretch a two-minute interval into "refresh duration + two minutes".
        self.timerTask = Task.detached(priority: .utility) { [weak self] in
            await Self.runFixedRefreshTimer(
                interval: .seconds(wait),
                sleepOverride: fixedTimerSleepOverride,
                refresh: { [weak self] in
                    await self?.refresh(enrichmentMode: .automatic)
                })
        }
    }

    deinit {
        self.timerTask?.cancel()
        self.tokenRefreshSequenceTask?.cancel()
        self.codexCostCatchUpTask?.cancel()
        self.forcedRefreshEnrichmentTask?.cancel()
        self.pendingForcedRefreshEnrichmentTask?.cancel()
        self.requiredRefreshTask?.cancel()
        self.creditsRefreshTask?.cancel()
        self.openAIDashboardBackgroundRefreshTask?.cancel()
        self.openAIDashboardRefreshTask?.cancel()
        self.memoryPressureReliefTask?.cancel()
        self.startupConnectivityRetryTask?.cancel()
        self.storageRefreshTask?.cancel()
        self.codexPlanHistoryBackfillTask?.cancel()
        self.resetBoundaryRefreshTask?.cancel()
        self.planUtilizationHistoryLoadTask?.cancel()
    }

    enum SessionQuotaWindowSource: String {
        case primary
        case copilotSecondaryFallback
        case antigravityQuotaSummary
        case antigravityLegacy
    }

    func postQuotaWarning(_ event: QuotaWarningEvent, provider: UsageProvider) {
        self.sessionQuotaNotifier.postQuotaWarning(
            event: event,
            provider: provider,
            soundEnabled: self.settings.quotaWarningSoundEnabled,
            onScreenAlertEnabled: self.settings.quotaWarningOnScreenAlertEnabled)
    }

    func postPredictivePaceWarning(_ event: PredictivePaceWarningEvent, provider: UsageProvider, now: Date) {
        self.sessionQuotaNotifier.postPredictivePaceWarning(
            event: event,
            provider: provider,
            soundEnabled: self.settings.quotaWarningSoundEnabled,
            onScreenAlertEnabled: self.settings.quotaWarningOnScreenAlertEnabled,
            now: now)
    }
}

extension UsageStore {
    func debugDumpClaude() async {
        // Provider-specific by design: Claude's debug command owns a raw CLI/web probe artifact and error lane.
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
                self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider.instanceID)
                self.errors[provider.instanceID] = "Failed to save log: \(error.localizedDescription)"
            }
            return nil
        }
    }

    func debugAugmentDump() async -> String {
        await AugmentStatusProbe.latestDumps()
    }

    func debugLog(for provider: UsageProvider) async -> String {
        if let cached = self.probeLogs[provider.instanceID], !cached.isEmpty {
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
        let notionCookieSource = self.settings.notionCookieSource
        let notionCookieHeader = self.settings.notionCookieHeader
        let notionWorkspaceID = self.settings.notionWorkspaceID
        let processEnvironment = self.environmentBase
        let apiKeyDebugContext = self.apiKeyDebugContext(
            provider: provider,
            processEnvironment: processEnvironment)
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
            // Provider-specific by design: implemented logs capture app-only settings and execution contexts.
            let buildText = {
                if let apiKeyDebugContext {
                    return Self.apiKeyDebugLine(apiKeyDebugContext)
                }
                switch provider {
                case .codex:
                    return await codexFetcher.debugRawRateLimits()
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
                    let resolution = ProviderTokenResolver.resolution(for: .zai)
                    let hasAny = resolution != nil
                    let source = resolution?.source.rawValue ?? "none"
                    return "Z_AI_API_KEY=\(hasAny ? "present" : "missing") source=\(source)"
                case .synthetic:
                    let resolution = ProviderTokenResolver.resolution(for: .synthetic)
                    let hasAny = resolution != nil
                    let source = resolution?.source.rawValue ?? "none"
                    return "SYNTHETIC_API_KEY=\(hasAny ? "present" : "missing") source=\(source)"
                case .cursor:
                    return await Self.debugCursorLog(
                        browserDetection: browserDetection,
                        cursorCookieSource: cursorCookieSource,
                        cursorCookieHeader: cursorCookieHeader)
                case .minimax:
                    let tokenResolution = ProviderTokenResolver.resolution(for: .minimax)
                    let cookieResolution = ProviderTokenResolver.resolution(for: .minimax, kind: .secondary)
                    let tokenSource = tokenResolution?.source.rawValue ?? "none"
                    let cookieSource = cookieResolution?.source.rawValue ?? "none"
                    return "MINIMAX_API_KEY=\(tokenResolution == nil ? "missing" : "present") " +
                        "source=\(tokenSource) MINIMAX_COOKIE=\(cookieResolution == nil ? "missing" : "present") " +
                        "source=\(cookieSource)"
                case .alibaba:
                    let resolution = ProviderTokenResolver.resolution(for: .alibaba)
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
                case .notion:
                    return await Self.debugNotionLog(
                        browserDetection: browserDetection,
                        notionCookieSource: notionCookieSource,
                        notionCookieHeader: notionCookieHeader,
                        notionWorkspaceID: notionWorkspaceID)
                case .warp:
                    let resolution = ProviderTokenResolver.resolution(for: .warp)
                    let hasAny = resolution != nil
                    let source = resolution?.source.rawValue ?? "none"
                    return "WARP_API_KEY=\(hasAny ? "present" : "missing") source=\(source)"
                case .deepseek:
                    return Self.apiKeyDebugLine(
                        label: "DEEPSEEK_API_KEY",
                        resolution: ProviderTokenResolver.resolution(for: .deepseek, environment: deepSeekEnvironment),
                        configToken: nil,
                        hasEnvToken: deepSeekHasEnvToken,
                        hasTokenAccount: deepSeekHasTokenAccount)
                default:
                    return ProviderDescriptorRegistry.descriptor(for: provider).metadata.debugLogUnavailableMessage
                        ?? "Debug log not yet implemented"
                }
            }
            return await claudeDebugExecutionContext.apply {
                await buildText()
            }
        }.value
        self.probeLogs[provider.instanceID] = text
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

    /// Version probes can spawn subprocesses (Antigravity's `ps` scan trips a TCC
    /// prompt, CLI providers exec their binaries), so disabled providers must not
    /// be probed (#2267). Settings changes re-run this when the enabled set changes.
    static func versionDetectionImplementations(
        enabled: Set<UsageProvider>) -> [any ProviderImplementation]
    {
        ProviderCatalog.all.filter { enabled.contains($0.id) }
    }

    func detectVersions() {
        let enabled = Set(self.settings.enabledProvidersOrdered(metadataByProvider: self.providerMetadata))
        self.versionDetectionProviders = enabled
        let implementations = Self.versionDetectionImplementations(
            enabled: Set(enabled.compactMap(\.firstPartyProvider)))
        // Provider-specific by design: only Claude's version probe is background-gated and needs recovery handling.
        let probesClaude = implementations.contains { $0.id == .claude }
        let browserDetection = self.browserDetection
        self.versionDetectionTask = Task { @MainActor [weak self] in
            let detection = await Task.detached { () -> (
                resolved: [UsageProvider: String],
                claudeBinaryResolvable: Bool) in
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
                // Provider-specific by design: disabled providers must not be probed (#2267), so the
                // Claude binary resolves only when Claude was in this run and its probe returned nil.
                let claudeBinaryResolvable = probesClaude
                    && resolved[.claude] == nil
                    && ProviderVersionDetector.claudeBinaryResolvable()
                return (resolved, claudeBinaryResolvable)
            }.value
            guard let self else { return }
            let resolved = detection.resolved
            var versions = Dictionary(uniqueKeysWithValues: resolved.map { ($0.key.instanceID, $0.value) })
            let claudeID = UsageProvider.claude.instanceID
            // A gated or failed Claude probe preserves a user-initiated recovery while the binary still resolves.
            // A missing/uninstalled binary clears the version so stale data does not survive CLI removal.
            if probesClaude,
               resolved[.claude] == nil,
               detection.claudeBinaryResolvable,
               let recoveredClaudeVersion = self.versions[claudeID]
            {
                versions[claudeID] = recoveredClaudeVersion
            }
            self.versions = versions
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

    func refreshTokenUsage(_ provider: UsageProvider, force: Bool) async {
        guard ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost else {
            self.resetTokenUsageState(for: provider)
            return
        }

        if Self.tokenCostRequiresProviderSnapshot(provider) {
            if self.tokenSnapshotPublicationForCurrentProviderConfig(for: provider) != nil {
                self.tokenErrors[provider.instanceID] = nil
                self.tokenFailureGates[provider.instanceID]?.recordSuccess()
                self.persistWidgetSnapshot(reason: "token-usage")
            } else {
                self.clearTokenSnapshot(for: provider)
                self.tokenErrors[provider.instanceID] = nil
                self.tokenFailureGates[provider.instanceID]?.reset()
            }
            return
        }

        guard self.settings.isCostUsageEffectivelyEnabled(for: provider) else {
            self.resetTokenUsageState(for: provider)
            return
        }

        guard self.isEnabled(provider) else {
            self.resetTokenUsageState(for: provider)
            return
        }

        // Provider-specific by design: Cursor cost shares the dashboard-cookie source policy with status fetching.
        // Cursor cost honors the same cookie policy as status: when the user set the cookie source
        // to Off, skip the network fetch entirely (mirrors CursorProviderDescriptor.checkStatus).
        if provider == .cursor, self.settings.cursorCookieSource == .off {
            self.resetTokenUsageState(for: provider)
            return
        }

        guard !self.tokenRefreshInFlight.contains(provider.instanceID) else { return }

        let now = Date()
        let historyDays = self.settings.costUsageHistoryDays
        // Cursor cost reuses the status cookie policy: a Manual source forwards the manual header so
        // cost and status share the same session; other sources fall back to auto resolution.
        guard case let .proceed(cursorCookieHeaderOverride) = self.prepareCursorCostCookie(for: provider) else {
            return
        }
        let costScope = self.tokenCostScope(for: provider)
        let costScopeSignature = self.tokenSnapshotScopeSignature(for: provider)
        let publicationRevision = self.providerPublicationRevision(for: provider)
        let providerConfigRevision = self.settings.providerConfigRevision(for: provider)
        if !force, self.tokenRefreshCanReuseCurrentSnapshot(
            provider: provider,
            now: now,
            costScopeSignature: costScopeSignature)
        {
            return
        }
        self.lastTokenFetchAt[provider.instanceID] = now
        self.lastTokenFetchScope[provider.instanceID] = costScopeSignature
        self.tokenRefreshInFlight.insert(provider.instanceID)
        defer { self.tokenRefreshInFlight.remove(provider.instanceID) }

        if let override = self._test_tokenUsageRefreshOverride {
            await override(provider, force)
            if Task.isCancelled {
                self.lastTokenFetchAt.removeValue(forKey: provider.instanceID)
                self.lastTokenFetchScope.removeValue(forKey: provider.instanceID)
            }
            return
        }

        let startedAt = Date()
        self.tokenCostLogger
            .debug("cost usage start provider=\(provider.rawValue) force=\(force)")

        do {
            // Codex cost usage scans the explicit token-cost scope: selected managed account by
            // default, or this Mac's ambient Codex home when the local ledger is enabled.
            let snapshot = try await self.loadTokenUsageSnapshot(
                provider: provider,
                force: force,
                now: now,
                codexHomePath: costScope.codexHomePath,
                historyDays: historyDays,
                cursorCookieHeaderOverride: cursorCookieHeaderOverride)
            try Task.checkCancellation()
            let completedCostScopeSignature = self.completedTokenCostScopeSignature(
                provider: provider,
                historyDays: historyDays,
                initialSignature: costScopeSignature,
                snapshot: snapshot)
            guard self.tokenRefreshPublicationIsCurrent(
                provider: provider,
                publicationRevision: publicationRevision,
                providerConfigRevision: providerConfigRevision,
                historyDays: historyDays,
                costScopeSignature: costScopeSignature,
                fetchedCredentialScopeFingerprint: snapshot.credentialScopeFingerprint)
            else {
                self.clearTokenFetchMetadataIfMatching(
                    provider: provider,
                    attemptedAt: now,
                    costScopeSignature: costScopeSignature)
                self.requestTokenRefreshAfterStaleCompletion(for: provider)
                return
            }
            self.lastTokenFetchScope[provider.instanceID] = completedCostScopeSignature
            self.startCodexCostCatchUpIfNeeded(afterRefreshing: provider)

            guard !snapshot.daily.isEmpty || snapshot.meteredCostUSD != nil else {
                self.publishConfirmedEmptyTokenSnapshot(for: provider)
                self.tokenErrors[provider.instanceID] = Self.tokenCostNoDataMessage(for: provider)
                self.tokenFailureGates[provider.instanceID]?.recordSuccess()
                return
            }
            self.logTokenUsageSuccess(
                provider: provider,
                snapshot: snapshot,
                historyDays: historyDays,
                startedAt: startedAt)
            self.publishTokenSnapshot(snapshot, for: provider)
            self.tokenErrors[provider.instanceID] = nil
            self.tokenFailureGates[provider.instanceID]?.recordSuccess()
            self.persistWidgetSnapshot(reason: "token-usage")
        } catch {
            guard self.tokenRefreshPublicationIsCurrent(
                provider: provider,
                publicationRevision: publicationRevision,
                providerConfigRevision: providerConfigRevision,
                historyDays: historyDays,
                costScopeSignature: costScopeSignature)
            else {
                self.clearTokenFetchMetadataIfMatching(
                    provider: provider,
                    attemptedAt: now,
                    costScopeSignature: costScopeSignature)
                self.requestTokenRefreshAfterStaleCompletion(for: provider)
                return
            }
            if error is CancellationError {
                self.clearTokenFetchMetadataIfMatching(
                    provider: provider,
                    attemptedAt: now,
                    costScopeSignature: costScopeSignature)
                return
            }
            let duration = Date().timeIntervalSince(startedAt)
            let msg = error.localizedDescription
            let durationText = String(format: "%.2f", duration)
            let message = "cost usage failed provider=\(provider.rawValue) duration=\(durationText)s error=\(msg)"
            self.tokenCostLogger.error(message)
            if Self.tokenFetchFailureAllowsEarlyRetry(error) {
                self.clearTokenFetchMetadataIfMatching(
                    provider: provider,
                    attemptedAt: now,
                    costScopeSignature: costScopeSignature)
            }
            let currentPublication = self.tokenSnapshotPublicationForCurrentProviderConfig(for: provider)
            let shouldSurface = self.tokenFailureGates[provider.instanceID]?
                .shouldSurfaceError(onFailureWithPriorData: currentPublication?.snapshot != nil) ?? true
            if shouldSurface {
                self.tokenErrors[provider.instanceID] = error.localizedDescription
                if currentPublication != nil { self.clearTokenSnapshot(for: provider) }
            } else {
                self.tokenErrors[provider.instanceID] = nil
            }
        }
    }

    private func resetTokenUsageState(for provider: UsageProvider) {
        // Provider-specific by design: resetting Codex token state also cancels its two ledger catch-up workflows.
        if provider == .codex {
            self.cancelCodexCostCatchUp()
            self.cancelSpendDashboardCodexCostCatchUp()
        }
        self.clearTokenSnapshot(for: provider)
        self.clearSpendDashboardTokenSnapshot(for: provider)
        self.tokenErrors[provider.instanceID] = nil
        self.tokenFailureGates[provider.instanceID]?.reset()
        self.lastTokenFetchAt.removeValue(forKey: provider.instanceID)
        self.lastTokenFetchScope.removeValue(forKey: provider.instanceID)
        self.lastSpendDashboardTokenFetchAt.removeValue(forKey: provider.instanceID)
        self.lastSpendDashboardTokenFetchScope.removeValue(forKey: provider.instanceID)
    }

    private func logTokenUsageSuccess(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot,
        historyDays: Int,
        startedAt: Date)
    {
        let durationText = String(format: "%.2f", Date().timeIntervalSince(startedAt))
        let sessionCost = snapshot.sessionCostUSD
            .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
        let monthCost = snapshot.last30DaysCostUSD
            .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
        let message =
            "cost usage success provider=\(provider.rawValue) " +
            "duration=\(durationText)s " +
            "today=\(sessionCost) " +
            "historyDays=\(historyDays) windowCost=\(monthCost)"
        self.tokenCostLogger.info(message)
    }

    private func clearTokenFetchMetadataIfMatching(
        provider: UsageProvider,
        attemptedAt: Date,
        costScopeSignature: String)
    {
        guard self.lastTokenFetchAt[provider.instanceID] == attemptedAt,
              self.lastTokenFetchScope[provider.instanceID] == costScopeSignature
        else {
            return
        }
        self.lastTokenFetchAt.removeValue(forKey: provider.instanceID)
        self.lastTokenFetchScope.removeValue(forKey: provider.instanceID)
    }

    /// Fast failures may retry on the next scheduled pass instead of waiting out the fetch
    /// TTL; timed-out scans keep the TTL so a slow corpus cannot thrash back-to-back rescans.
    nonisolated static func tokenFetchFailureAllowsEarlyRetry(_ error: Error) -> Bool {
        if case CostUsageError.timedOut = error {
            return false
        }
        return true
    }
}

extension UsageStore {
    func retainCodingActivityIfNewer(_ date: Date) {
        if self.lastCodingActivityAt.map({ date > $0 }) ?? true {
            self.lastCodingActivityAt = date
        }
    }

    func clearCodingActivityObservation() {
        self.lastCodingActivityAt = nil
    }

    func restartAdaptiveTimerPreservingResetBoundary() {
        self.startTimer(preservingResetBoundaryRefresh: true)
    }

    func noteMenuOpened(at date: Date = Date()) {
        self.lastMenuOpenAt = date
        self.advanceAdaptiveTimerIfEarlier(at: date)
    }
}
