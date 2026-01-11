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
        _ = self.lastSourceLabels
        _ = self.lastFetchAttempts
        _ = self.tokenSnapshots
        _ = self.tokenErrors
        _ = self.tokenRefreshInFlight
        _ = self.credits
        _ = self.lastCreditsError
        _ = self.openAIDashboard
        _ = self.lastOpenAIDashboardError
        _ = self.openAIDashboardRequiresLogin
        _ = self.openAIDashboardCookieImportStatus
        _ = self.openAIDashboardCookieImportDebugLog
        _ = self.codexVersion
        _ = self.claudeVersion
        _ = self.geminiVersion
        _ = self.zaiVersion
        _ = self.antigravityVersion
        _ = self.kiroVersion
        _ = self.isRefreshing
        _ = self.refreshingProviders
        _ = self.pathDebugInfo
        _ = self.statuses
        _ = self.probeLogs
        return 0
    }

    func observeSettingsChanges() {
        withObservationTracking {
            _ = self.settings.refreshFrequency
            _ = self.settings.statusChecksEnabled
            _ = self.settings.sessionQuotaNotificationsEnabled
            _ = self.settings.usageBarsShowUsed
            _ = self.settings.costUsageEnabled
            _ = self.settings.randomBlinkEnabled
            _ = self.settings.claudeWebExtrasEnabled
            _ = self.settings.codexUsageDataSource
            _ = self.settings.claudeUsageDataSource
            _ = self.settings.codexCookieSource
            _ = self.settings.claudeCookieSource
            _ = self.settings.cursorCookieSource
            _ = self.settings.factoryCookieSource
            _ = self.settings.minimaxCookieSource
            _ = self.settings.codexCookieHeader
            _ = self.settings.claudeCookieHeader
            _ = self.settings.cursorCookieHeader
            _ = self.settings.factoryCookieHeader
            _ = self.settings.minimaxCookieHeader
            _ = self.settings.mergeIcons
            _ = self.settings.selectedMenuProvider
            _ = self.settings.debugLoadingPattern
            _ = self.settings.augmentCookieSource
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeSettingsChanges()
                self.startTimer()
                self.restartAugmentKeepaliveIfNeeded()
                await self.refresh()
            }
        }
    }

    private func restartAugmentKeepaliveIfNeeded() {
        #if os(macOS)
        let shouldRun = self.isEnabled(.augment)
        let isRunning = self.augmentKeepalive != nil

        if shouldRun, !isRunning {
            self.startAugmentKeepalive()
        } else if !shouldRun, isRunning {
            Task { @MainActor in
                self.augmentKeepalive?.stop()
                self.augmentKeepalive = nil
                print("[CodexBar] Augment session keepalive stopped (provider disabled)")
            }
        }
        #endif
    }
}

// MARK: - OpenAI web error messaging

extension UsageStore {
    private func openAIDashboardFriendlyError(
        body: String,
        targetEmail: String?,
        cookieImportStatus: String?) -> String?
    {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = cookieImportStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return [
                "OpenAI web dashboard returned an empty page.",
                "Sign in to chatgpt.com and update OpenAI cookies in Providers → Codex.",
            ].joined(separator: " ")
        }

        let lower = trimmed.lowercased()
        let looksLikePublicLanding = lower.contains("skip to content")
            && (lower.contains("about") || lower.contains("openai") || lower.contains("chatgpt"))
        let looksLoggedOut = lower.contains("sign in")
            || lower.contains("log in")
            || lower.contains("create account")
            || lower.contains("continue with google")
            || lower.contains("continue with apple")
            || lower.contains("continue with microsoft")

        guard looksLikePublicLanding || looksLoggedOut else { return nil }
        let emailLabel = targetEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetLabel = (emailLabel?.isEmpty == false) ? emailLabel! : "your OpenAI account"
        if let status, !status.isEmpty {
            if status.contains("cookies do not match Codex account")
                || status.localizedCaseInsensitiveContains("cookie import failed")
            {
                return [
                    status,
                    "Sign in to chatgpt.com as \(targetLabel), then update OpenAI cookies in Providers → Codex.",
                ].joined(separator: " ")
            }
        }
        return [
            "OpenAI web dashboard returned a public page (not signed in).",
            "Sign in to chatgpt.com as \(targetLabel), then update OpenAI cookies in Providers → Codex.",
        ].joined(separator: " ")
    }
}

enum ProviderStatusIndicator: String {
    case none
    case minor
    case major
    case critical
    case maintenance
    case unknown

    var hasIssue: Bool {
        switch self {
        case .none: false
        default: true
        }
    }

    var label: String {
        switch self {
        case .none: "Operational"
        case .minor: "Partial outage"
        case .major: "Major outage"
        case .critical: "Critical issue"
        case .maintenance: "Maintenance"
        case .unknown: "Status unknown"
        }
    }
}

#if DEBUG
extension UsageStore {
    func _setSnapshotForTesting(_ snapshot: UsageSnapshot?, provider: UsageProvider) {
        self.snapshots[provider] = snapshot?.scoped(to: provider)
    }

    func _setTokenSnapshotForTesting(_ snapshot: CostUsageTokenSnapshot?, provider: UsageProvider) {
        self.tokenSnapshots[provider] = snapshot
    }

    func _setTokenErrorForTesting(_ error: String?, provider: UsageProvider) {
        self.tokenErrors[provider] = error
    }

    func _setErrorForTesting(_ error: String?, provider: UsageProvider) {
        self.errors[provider] = error
    }
}
#endif

struct ProviderStatus {
    let indicator: ProviderStatusIndicator
    let description: String?
    let updatedAt: Date?
}

/// Tracks consecutive failures so we can ignore a single flake when we previously had fresh data.
struct ConsecutiveFailureGate {
    private(set) var streak: Int = 0

    mutating func recordSuccess() {
        self.streak = 0
    }

    mutating func reset() {
        self.streak = 0
    }

    /// Returns true when the caller should surface the error to the UI.
    mutating func shouldSurfaceError(onFailureWithPriorData hadPriorData: Bool) -> Bool {
        self.streak += 1
        if hadPriorData, self.streak == 1 { return false }
        return true
    }
}

@MainActor
@Observable
final class UsageStore {
    private(set) var snapshots: [UsageProvider: UsageSnapshot] = [:]
    private(set) var errors: [UsageProvider: String] = [:]
    private(set) var lastSourceLabels: [UsageProvider: String] = [:]
    private(set) var lastFetchAttempts: [UsageProvider: [ProviderFetchAttempt]] = [:]
    private(set) var tokenSnapshots: [UsageProvider: CostUsageTokenSnapshot] = [:]
    private(set) var tokenErrors: [UsageProvider: String] = [:]
    private(set) var tokenRefreshInFlight: Set<UsageProvider> = []
    var credits: CreditsSnapshot?
    var lastCreditsError: String?
    var openAIDashboard: OpenAIDashboardSnapshot?
    var lastOpenAIDashboardError: String?
    private(set) var openAIDashboardRequiresLogin: Bool = false
    var openAIDashboardCookieImportStatus: String?
    var openAIDashboardCookieImportDebugLog: String?
    var codexVersion: String?
    var claudeVersion: String?
    var geminiVersion: String?
    var zaiVersion: String?
    var antigravityVersion: String?
    var cursorVersion: String?
    var kiroVersion: String?
    var isRefreshing = false
    private(set) var refreshingProviders: Set<UsageProvider> = []
    var debugForceAnimation = false
    var pathDebugInfo: PathDebugSnapshot = .empty
    private(set) var statuses: [UsageProvider: ProviderStatus] = [:]
    private(set) var probeLogs: [UsageProvider: String] = [:]
    @ObservationIgnored private var lastCreditsSnapshot: CreditsSnapshot?
    @ObservationIgnored private var creditsFailureStreak: Int = 0
    @ObservationIgnored private var lastOpenAIDashboardSnapshot: OpenAIDashboardSnapshot?
    @ObservationIgnored private var lastOpenAIDashboardTargetEmail: String?
    @ObservationIgnored private var lastOpenAIDashboardCookieImportAttemptAt: Date?
    @ObservationIgnored private var lastOpenAIDashboardCookieImportEmail: String?
    @ObservationIgnored private var openAIWebAccountDidChange: Bool = false

    @ObservationIgnored private let codexFetcher: UsageFetcher
    @ObservationIgnored private let claudeFetcher: any ClaudeUsageFetching
    @ObservationIgnored private let costUsageFetcher: CostUsageFetcher
    @ObservationIgnored let browserDetection: BrowserDetection
    @ObservationIgnored private let registry: ProviderRegistry
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let sessionQuotaNotifier: SessionQuotaNotifier
    @ObservationIgnored private let sessionQuotaLogger = CodexBarLog.logger("sessionQuota")
    @ObservationIgnored private let openAIWebLogger = CodexBarLog.logger("openai-web")
    @ObservationIgnored private let tokenCostLogger = CodexBarLog.logger("token-cost")
    @ObservationIgnored private var openAIWebDebugLines: [String] = []
    @ObservationIgnored private var failureGates: [UsageProvider: ConsecutiveFailureGate] = [:]
    @ObservationIgnored private var tokenFailureGates: [UsageProvider: ConsecutiveFailureGate] = [:]
    @ObservationIgnored private var providerSpecs: [UsageProvider: ProviderSpec] = [:]
    @ObservationIgnored private let providerMetadata: [UsageProvider: ProviderMetadata]
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var tokenTimerTask: Task<Void, Never>?
    @ObservationIgnored private var tokenRefreshSequenceTask: Task<Void, Never>?
    @ObservationIgnored private var lastKnownSessionRemaining: [UsageProvider: Double] = [:]
    @ObservationIgnored private(set) var lastTokenFetchAt: [UsageProvider: Date] = [:]
    @ObservationIgnored private let tokenFetchTTL: TimeInterval = 60 * 60
    @ObservationIgnored private let tokenFetchTimeout: TimeInterval = 10 * 60
    @ObservationIgnored private var augmentKeepalive: AugmentSessionKeepalive?

    init(
        fetcher: UsageFetcher,
        browserDetection: BrowserDetection,
        claudeFetcher: (any ClaudeUsageFetching)? = nil,
        costUsageFetcher: CostUsageFetcher = CostUsageFetcher(),
        settings: SettingsStore,
        registry: ProviderRegistry = .shared,
        sessionQuotaNotifier: SessionQuotaNotifier = SessionQuotaNotifier())
    {
        self.codexFetcher = fetcher
        self.browserDetection = browserDetection
        self.claudeFetcher = claudeFetcher ?? ClaudeUsageFetcher(browserDetection: browserDetection)
        self.costUsageFetcher = costUsageFetcher
        self.settings = settings
        self.registry = registry
        self.sessionQuotaNotifier = sessionQuotaNotifier
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
            browserDetection: browserDetection)
        self.bindSettings()
        self.detectVersions()
        self.refreshPathDebugInfo()
        LoginShellPathCache.shared.captureOnce { [weak self] _ in
            Task { @MainActor in self?.refreshPathDebugInfo() }
        }
        Task { await self.refresh() }
        self.startTimer()
        self.startTokenTimer()
        self.startAugmentKeepalive()
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
        guard let method = loginMethod?.lowercased(), !method.isEmpty else {
            return false
        }
        let subscriptionIndicators = ["max", "pro", "ultra", "team"]
        return subscriptionIndicators.contains { method.contains($0) }
    }

    func version(for provider: UsageProvider) -> String? {
        switch provider {
        case .codex: self.codexVersion
        case .claude: self.claudeVersion
        case .zai: self.zaiVersion
        case .gemini: self.geminiVersion
        case .antigravity: self.antigravityVersion
        case .cursor: self.cursorVersion
        case .factory: nil
        case .copilot: nil
        case .minimax: nil
        case .vertexai: nil
        case .kiro: self.kiroVersion
        case .augment: nil
        case .jetbrains: nil
        }
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
        (self.isEnabled(.codex) && self.lastCodexError != nil) ||
            (self.isEnabled(.claude) && self.lastClaudeError != nil) ||
            (self.isEnabled(.zai) && self.errors[.zai] != nil) ||
            (self.isEnabled(.gemini) && self.errors[.gemini] != nil) ||
            (self.isEnabled(.antigravity) && self.errors[.antigravity] != nil) ||
            (self.isEnabled(.cursor) && self.errors[.cursor] != nil) ||
            (self.isEnabled(.factory) && self.errors[.factory] != nil) ||
            (self.isEnabled(.copilot) && self.errors[.copilot] != nil) ||
            (self.isEnabled(.minimax) && self.errors[.minimax] != nil)
    }

    func enabledProviders() -> [UsageProvider] {
        // Use cached enablement to avoid repeated UserDefaults lookups in animation ticks.
        let enabled = self.settings.enabledProvidersOrdered(metadataByProvider: self.providerMetadata)
        return enabled.filter { self.isProviderAvailable($0) }
    }

    var statusChecksEnabled: Bool {
        self.settings.statusChecksEnabled
    }

    func metadata(for provider: UsageProvider) -> ProviderMetadata {
        self.providerMetadata[provider]!
    }

    private var codexBrowserCookieOrder: BrowserCookieImportOrder {
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
            } else if provider == .codex {
                label = self.settings.codexUsageDataSource.rawValue
            } else if provider == .claude {
                label = self.settings.claudeUsageDataSource.rawValue
            } else {
                label = "auto"
            }
        }

        // When OpenAI web extras are active, show a blended label like `oauth + openai-web`.
        if provider == .codex,
           self.settings.codexCookieSource.isEnabled,
           self.openAIDashboard != nil,
           !self.openAIDashboardRequiresLogin,
           !label.contains("openai-web")
        {
            return "\(label) + openai-web"
        }
        return label
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

    func isEnabled(_ provider: UsageProvider) -> Bool {
        let enabled = self.settings.isProviderEnabledCached(
            provider: provider,
            metadataByProvider: self.providerMetadata)
        guard enabled else { return false }
        return self.isProviderAvailable(provider)
    }

    private func isProviderAvailable(_ provider: UsageProvider) -> Bool {
        if provider == .zai {
            if ZaiSettingsReader.apiToken(environment: ProcessInfo.processInfo.environment) != nil {
                return true
            }
            return !self.settings.zaiAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    func refresh(forceTokenUsage: Bool = false) async {
        guard !self.isRefreshing else { return }
        self.isRefreshing = true
        defer { self.isRefreshing = false }

        await withTaskGroup(of: Void.self) { group in
            for provider in UsageProvider.allCases {
                group.addTask { await self.refreshProvider(provider) }
                group.addTask { await self.refreshStatus(provider) }
            }
            group.addTask { await self.refreshCreditsIfNeeded() }
        }

        // Token-cost usage can be slow; run it outside the refresh group so we don't block menu updates.
        self.scheduleTokenRefresh(force: forceTokenUsage)

        // OpenAI web scrape depends on the current Codex account email (which can change after login/account switch).
        // Run this after Codex usage refresh so we don't accidentally scrape with stale credentials.
        await self.refreshOpenAIDashboardIfNeeded(force: forceTokenUsage)

        if self.openAIDashboardRequiresLogin {
            await self.refreshProvider(.codex)
            await self.refreshCreditsIfNeeded()
        }

        self.persistWidgetSnapshot(reason: "refresh")
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

    private func startTimer() {
        self.timerTask?.cancel()
        guard let wait = self.settings.refreshFrequency.seconds else { return }

        // Background poller so the menu stays responsive; canceled when settings change or store deallocates.
        self.timerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait))
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
            for provider in UsageProvider.allCases {
                if Task.isCancelled { break }
                await self.refreshTokenUsage(provider, force: force)
            }
        }
    }

    deinit {
        self.timerTask?.cancel()
        self.tokenTimerTask?.cancel()
        self.tokenRefreshSequenceTask?.cancel()
        // Note: augmentKeepalive.stop() is @MainActor, can't call from deinit
        // The timer task will be cancelled when augmentKeepalive is deallocated
    }

    private func startAugmentKeepalive() {
        #if os(macOS)
        print("[CodexBar] 🔍 Checking if Augment keepalive should start...")
        print("[CodexBar]   - Augment enabled: \(self.isEnabled(.augment))")
        print("[CodexBar]   - Augment available: \(self.isProviderAvailable(.augment))")

        // Only start keepalive if Augment is enabled
        guard self.isEnabled(.augment) else {
            print("[CodexBar] ⚠️ Augment keepalive NOT started - provider is disabled")
            print("[CodexBar]   Tip: Enable Augment in Settings to activate automatic session management")
            return
        }

        let logger: (String) -> Void = { message in
            print("[CodexBar] \(message)")
        }

        self.augmentKeepalive = AugmentSessionKeepalive(logger: logger)
        self.augmentKeepalive?.start()
        print("[CodexBar] ✅ Augment session keepalive STARTED successfully")
        #endif
    }

    /// Force refresh Augment session (called from UI button)
    func forceRefreshAugmentSession() async {
        #if os(macOS)
        print("[CodexBar] 🔄 Force refresh Augment session requested")
        guard let keepalive = self.augmentKeepalive else {
            print("[CodexBar] ⚠️ Augment keepalive not running - starting it now")
            self.startAugmentKeepalive()
            // Give it a moment to start
            try? await Task.sleep(for: .seconds(1))
            guard let keepalive = self.augmentKeepalive else {
                print("[CodexBar] ✗ Failed to start Augment keepalive")
                return
            }
            await keepalive.forceRefresh()
            return
        }

        await keepalive.forceRefresh()

        // Refresh usage after forcing session refresh
        print("[CodexBar] 🔄 Refreshing Augment usage after session refresh")
        await self.refreshProvider(.augment)
        #endif
    }

    private func refreshProvider(_ provider: UsageProvider) async {
        guard let spec = self.providerSpecs[provider] else { return }

        if !spec.isEnabled() {
            self.refreshingProviders.remove(provider)
            await MainActor.run {
                self.snapshots.removeValue(forKey: provider)
                self.errors[provider] = nil
                self.lastSourceLabels.removeValue(forKey: provider)
                self.lastFetchAttempts.removeValue(forKey: provider)
                self.tokenSnapshots.removeValue(forKey: provider)
                self.tokenErrors[provider] = nil
                self.failureGates[provider]?.reset()
                self.tokenFailureGates[provider]?.reset()
                self.statuses.removeValue(forKey: provider)
                self.lastKnownSessionRemaining.removeValue(forKey: provider)
                self.lastTokenFetchAt.removeValue(forKey: provider)
            }
            return
        }

        self.refreshingProviders.insert(provider)
        defer { self.refreshingProviders.remove(provider) }

        let outcome = await spec.fetch()
        await MainActor.run {
            self.lastFetchAttempts[provider] = outcome.attempts
        }

        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: provider)
            await MainActor.run {
                self.handleSessionQuotaTransition(provider: provider, snapshot: scoped)
                self.snapshots[provider] = scoped
                self.lastSourceLabels[provider] = result.sourceLabel
                self.errors[provider] = nil
                self.failureGates[provider]?.recordSuccess()
            }
        case let .failure(error):
            await MainActor.run {
                let hadPriorData = self.snapshots[provider] != nil
                let shouldSurface = self.failureGates[provider]?
                    .shouldSurfaceError(onFailureWithPriorData: hadPriorData) ?? true
                if shouldSurface {
                    self.errors[provider] = error.localizedDescription
                    self.snapshots.removeValue(forKey: provider)
                } else {
                    self.errors[provider] = nil
                }
            }
        }
    }

    private func handleSessionQuotaTransition(provider: UsageProvider, snapshot: UsageSnapshot) {
        guard let primary = snapshot.primary else { return }
        let currentRemaining = primary.remainingPercent
        let previousRemaining = self.lastKnownSessionRemaining[provider]

        defer { self.lastKnownSessionRemaining[provider] = currentRemaining }

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
                self.sessionQuotaNotifier.post(transition: .depleted, provider: provider)
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

        self.sessionQuotaNotifier.post(transition: transition, provider: provider)
    }

    private func refreshStatus(_ provider: UsageProvider) async {
        guard self.settings.statusChecksEnabled else { return }
        guard let meta = self.providerMetadata[provider] else { return }

        do {
            let status: ProviderStatus
            if let urlString = meta.statusPageURL, let baseURL = URL(string: urlString) {
                status = try await Self.fetchStatus(from: baseURL)
            } else if let productID = meta.statusWorkspaceProductID {
                status = try await Self.fetchWorkspaceStatus(productID: productID)
            } else {
                return
            }
            await MainActor.run { self.statuses[provider] = status }
        } catch {
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

    private func refreshCreditsIfNeeded() async {
        guard self.isEnabled(.codex) else { return }
        do {
            let credits = try await self.codexFetcher.loadLatestCredits()
            await MainActor.run {
                self.credits = credits
                self.lastCreditsError = nil
                self.lastCreditsSnapshot = credits
                self.creditsFailureStreak = 0
            }
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("data not available yet") {
                await MainActor.run {
                    if let cached = self.lastCreditsSnapshot {
                        self.credits = cached
                        self.lastCreditsError = nil
                    } else {
                        self.credits = nil
                        self.lastCreditsError = "Codex credits are still loading; will retry shortly."
                    }
                }
                return
            }

            await MainActor.run {
                self.creditsFailureStreak += 1
                if let cached = self.lastCreditsSnapshot {
                    self.credits = cached
                    let stamp = cached.updatedAt.formatted(date: .abbreviated, time: .shortened)
                    self.lastCreditsError =
                        "Last Codex credits refresh failed: \(message). Cached values from \(stamp)."
                } else {
                    self.lastCreditsError = message
                    self.credits = nil
                }
            }
        }
    }
}

extension UsageStore {
    private func applyOpenAIDashboard(_ dash: OpenAIDashboardSnapshot, targetEmail: String?) async {
        await MainActor.run {
            self.openAIDashboard = dash
            self.lastOpenAIDashboardError = nil
            self.lastOpenAIDashboardSnapshot = dash
            self.openAIDashboardRequiresLogin = false
            // Only fill gaps; OAuth/CLI remain the primary sources for usage + credits.
            if self.snapshots[.codex] == nil,
               let usage = dash.toUsageSnapshot(provider: .codex, accountEmail: targetEmail)
            {
                self.snapshots[.codex] = usage
                self.errors[.codex] = nil
                self.failureGates[.codex]?.recordSuccess()
                self.lastSourceLabels[.codex] = "openai-web"
            }
            if self.credits == nil, let credits = dash.toCreditsSnapshot() {
                self.credits = credits
                self.lastCreditsSnapshot = credits
                self.lastCreditsError = nil
                self.creditsFailureStreak = 0
            }
        }

        if let email = targetEmail, !email.isEmpty {
            OpenAIDashboardCacheStore.save(OpenAIDashboardCache(accountEmail: email, snapshot: dash))
        }
    }

    private func applyOpenAIDashboardFailure(message: String) async {
        await MainActor.run {
            if let cached = self.lastOpenAIDashboardSnapshot {
                self.openAIDashboard = cached
                let stamp = cached.updatedAt.formatted(date: .abbreviated, time: .shortened)
                self.lastOpenAIDashboardError =
                    "Last OpenAI dashboard refresh failed: \(message). Cached values from \(stamp)."
            } else {
                self.lastOpenAIDashboardError = message
                self.openAIDashboard = nil
            }
        }
    }

    private func refreshOpenAIDashboardIfNeeded(force: Bool = false) async {
        guard self.isEnabled(.codex), self.settings.codexCookieSource.isEnabled else {
            await MainActor.run {
                self.openAIDashboard = nil
                self.lastOpenAIDashboardError = nil
                self.lastOpenAIDashboardSnapshot = nil
                self.lastOpenAIDashboardTargetEmail = nil
                self.openAIDashboardRequiresLogin = false
                self.openAIDashboardCookieImportStatus = nil
                self.openAIDashboardCookieImportDebugLog = nil
                self.lastOpenAIDashboardCookieImportAttemptAt = nil
                self.lastOpenAIDashboardCookieImportEmail = nil
            }
            return
        }

        let targetEmail = self.codexAccountEmailForOpenAIDashboard()
        self.handleOpenAIWebTargetEmailChangeIfNeeded(targetEmail: targetEmail)

        let now = Date()
        let minInterval = max(self.settings.refreshFrequency.seconds ?? 0, 120)
        if !force,
           !self.openAIWebAccountDidChange,
           self.lastOpenAIDashboardError == nil,
           let snapshot = self.lastOpenAIDashboardSnapshot,
           now.timeIntervalSince(snapshot.updatedAt) < minInterval
        {
            return
        }

        if self.openAIWebDebugLines.isEmpty {
            self.resetOpenAIWebDebugLog(context: "refresh")
        } else {
            let stamp = Date().formatted(date: .abbreviated, time: .shortened)
            self.logOpenAIWeb("[\(stamp)] OpenAI web refresh start")
        }
        let log: (String) -> Void = { [weak self] line in
            guard let self else { return }
            self.logOpenAIWeb(line)
        }

        do {
            let normalized = targetEmail?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            var effectiveEmail = targetEmail

            // Use a per-email persistent `WKWebsiteDataStore` so multiple dashboard sessions can coexist.
            // Strategy:
            // - Try the existing per-email WebKit cookie store first (fast; avoids Keychain prompts).
            // - On login-required or account mismatch, import cookies from the configured browser order and retry once.
            if self.openAIWebAccountDidChange, let targetEmail, !targetEmail.isEmpty {
                // On account switches, proactively re-import cookies so we don't show stale data from the previous
                // user.
                if let imported = await self.importOpenAIDashboardCookiesIfNeeded(
                    targetEmail: targetEmail,
                    force: true)
                {
                    effectiveEmail = imported
                }
                self.openAIWebAccountDidChange = false
            }

            var dash = try await OpenAIDashboardFetcher().loadLatestDashboard(
                accountEmail: effectiveEmail,
                logger: log,
                debugDumpHTML: false)

            if self.dashboardEmailMismatch(expected: normalized, actual: dash.signedInEmail) {
                if let imported = await self.importOpenAIDashboardCookiesIfNeeded(
                    targetEmail: targetEmail,
                    force: true)
                {
                    effectiveEmail = imported
                }
                dash = try await OpenAIDashboardFetcher().loadLatestDashboard(
                    accountEmail: effectiveEmail,
                    logger: log,
                    debugDumpHTML: false)
            }

            if self.dashboardEmailMismatch(expected: normalized, actual: dash.signedInEmail) {
                let signedIn = dash.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                await MainActor.run {
                    self.openAIDashboard = nil
                    self.lastOpenAIDashboardError = [
                        "OpenAI dashboard signed in as \(signedIn), but Codex uses \(normalized ?? "unknown").",
                        "Switch accounts in your browser and update OpenAI cookies in Providers → Codex.",
                    ].joined(separator: " ")
                    self.openAIDashboardRequiresLogin = true
                }
                return
            }

            await self.applyOpenAIDashboard(dash, targetEmail: effectiveEmail)
        } catch let OpenAIDashboardFetcher.FetchError.noDashboardData(body) {
            // Often indicates a missing/stale session without an obvious login prompt. Retry once after
            // importing cookies from the user's browser.
            let targetEmail = self.codexAccountEmailForOpenAIDashboard()
            var effectiveEmail = targetEmail
            if let imported = await self.importOpenAIDashboardCookiesIfNeeded(targetEmail: targetEmail, force: true) {
                effectiveEmail = imported
            }
            do {
                let dash = try await OpenAIDashboardFetcher().loadLatestDashboard(
                    accountEmail: effectiveEmail,
                    logger: log,
                    debugDumpHTML: true)
                await self.applyOpenAIDashboard(dash, targetEmail: effectiveEmail)
            } catch let OpenAIDashboardFetcher.FetchError.noDashboardData(retryBody) {
                let finalBody = retryBody.isEmpty ? body : retryBody
                let message = self.openAIDashboardFriendlyError(
                    body: finalBody,
                    targetEmail: targetEmail,
                    cookieImportStatus: self.openAIDashboardCookieImportStatus)
                    ?? OpenAIDashboardFetcher.FetchError.noDashboardData(body: finalBody).localizedDescription
                await self.applyOpenAIDashboardFailure(message: message)
            } catch {
                await self.applyOpenAIDashboardFailure(message: error.localizedDescription)
            }
        } catch OpenAIDashboardFetcher.FetchError.loginRequired {
            let targetEmail = self.codexAccountEmailForOpenAIDashboard()
            var effectiveEmail = targetEmail
            if let imported = await self.importOpenAIDashboardCookiesIfNeeded(targetEmail: targetEmail, force: true) {
                effectiveEmail = imported
            }
            do {
                let dash = try await OpenAIDashboardFetcher().loadLatestDashboard(
                    accountEmail: effectiveEmail,
                    logger: log,
                    debugDumpHTML: true)
                await self.applyOpenAIDashboard(dash, targetEmail: effectiveEmail)
            } catch OpenAIDashboardFetcher.FetchError.loginRequired {
                await MainActor.run {
                    self.lastOpenAIDashboardError = [
                        "OpenAI web access requires a signed-in chatgpt.com session.",
                        "Sign in using \(self.codexBrowserCookieOrder.loginHint), " +
                            "then update OpenAI cookies in Providers → Codex.",
                    ].joined(separator: " ")
                    self.openAIDashboard = self.lastOpenAIDashboardSnapshot
                    self.openAIDashboardRequiresLogin = true
                }
            } catch {
                await self.applyOpenAIDashboardFailure(message: error.localizedDescription)
            }
        } catch {
            await self.applyOpenAIDashboardFailure(message: error.localizedDescription)
        }
    }

    // MARK: - OpenAI web account switching

    /// Detect Codex account email changes and clear stale OpenAI web state so the UI can't show the wrong user.
    /// This does not delete other per-email WebKit cookie stores (we keep multiple accounts around).
    func handleOpenAIWebTargetEmailChangeIfNeeded(targetEmail: String?) {
        let normalized = targetEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let normalized, !normalized.isEmpty else { return }

        let previous = self.lastOpenAIDashboardTargetEmail
        self.lastOpenAIDashboardTargetEmail = normalized

        if let previous,
           !previous.isEmpty,
           previous != normalized
        {
            let stamp = Date().formatted(date: .abbreviated, time: .shortened)
            self.logOpenAIWeb(
                "[\(stamp)] Codex account changed: \(previous) → \(normalized); " +
                    "clearing OpenAI web snapshot")
            self.openAIWebAccountDidChange = true
            self.openAIDashboard = nil
            self.lastOpenAIDashboardSnapshot = nil
            self.lastOpenAIDashboardError = nil
            self.openAIDashboardRequiresLogin = true
            self.openAIDashboardCookieImportStatus = "Codex account changed; importing browser cookies…"
            self.lastOpenAIDashboardCookieImportAttemptAt = nil
            self.lastOpenAIDashboardCookieImportEmail = nil
        }
    }

    func importOpenAIDashboardBrowserCookiesNow() async {
        self.resetOpenAIWebDebugLog(context: "manual import")
        let targetEmail = self.codexAccountEmailForOpenAIDashboard()
        _ = await self.importOpenAIDashboardCookiesIfNeeded(targetEmail: targetEmail, force: true)
        await self.refreshOpenAIDashboardIfNeeded(force: true)
    }

    private func importOpenAIDashboardCookiesIfNeeded(targetEmail: String?, force: Bool) async -> String? {
        let normalizedTarget = targetEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowAnyAccount = normalizedTarget == nil || normalizedTarget?.isEmpty == true
        let cookieSource = self.settings.codexCookieSource

        let now = Date()
        let lastEmail = self.lastOpenAIDashboardCookieImportEmail
        let lastAttempt = self.lastOpenAIDashboardCookieImportAttemptAt ?? .distantPast

        let shouldAttempt: Bool = if force {
            true
        } else {
            if allowAnyAccount {
                now.timeIntervalSince(lastAttempt) > 300
            } else {
                self.openAIDashboardRequiresLogin &&
                    (
                        lastEmail?.lowercased() != normalizedTarget?.lowercased() || now
                            .timeIntervalSince(lastAttempt) > 300)
            }
        }

        guard shouldAttempt else { return normalizedTarget }
        self.lastOpenAIDashboardCookieImportEmail = normalizedTarget
        self.lastOpenAIDashboardCookieImportAttemptAt = now

        let stamp = now.formatted(date: .abbreviated, time: .shortened)
        let targetLabel = normalizedTarget ?? "unknown"
        self.logOpenAIWeb("[\(stamp)] import start (target=\(targetLabel))")

        do {
            let log: (String) -> Void = { [weak self] message in
                guard let self else { return }
                self.logOpenAIWeb(message)
            }

            let importer = OpenAIDashboardBrowserCookieImporter(browserDetection: self.browserDetection)
            let result: OpenAIDashboardBrowserCookieImporter.ImportResult
            switch cookieSource {
            case .manual:
                self.settings.ensureCodexCookieLoaded()
                let manualHeader = self.settings.codexCookieHeader
                guard CookieHeaderNormalizer.normalize(manualHeader) != nil else {
                    throw OpenAIDashboardBrowserCookieImporter.ImportError.manualCookieHeaderInvalid
                }
                result = try await importer.importManualCookies(
                    cookieHeader: manualHeader,
                    intoAccountEmail: normalizedTarget,
                    allowAnyAccount: allowAnyAccount,
                    logger: log)
            case .auto:
                result = try await importer.importBestCookies(
                    intoAccountEmail: normalizedTarget,
                    allowAnyAccount: allowAnyAccount,
                    logger: log)
            case .off:
                result = OpenAIDashboardBrowserCookieImporter.ImportResult(
                    sourceLabel: "Off",
                    cookieCount: 0,
                    signedInEmail: normalizedTarget,
                    matchesCodexEmail: true)
            }
            let effectiveEmail = result.signedInEmail?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
                ? result.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
                : normalizedTarget
            self.lastOpenAIDashboardCookieImportEmail = effectiveEmail ?? normalizedTarget
            await MainActor.run {
                let signed = result.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
                let matchText = result.matchesCodexEmail ? "matches Codex" : "does not match Codex"
                let sourceLabel = switch cookieSource {
                case .manual:
                    "Manual cookie header"
                case .auto:
                    "\(result.sourceLabel) cookies"
                case .off:
                    "OpenAI cookies disabled"
                }
                if let signed, !signed.isEmpty {
                    self.openAIDashboardCookieImportStatus =
                        allowAnyAccount
                            ? [
                                "Using \(sourceLabel) (\(result.cookieCount)).",
                                "Signed in as \(signed).",
                            ].joined(separator: " ")
                            : [
                                "Using \(sourceLabel) (\(result.cookieCount)).",
                                "Signed in as \(signed) (\(matchText)).",
                            ].joined(separator: " ")
                } else {
                    self.openAIDashboardCookieImportStatus =
                        "Using \(sourceLabel) (\(result.cookieCount))."
                }
            }
            return effectiveEmail
        } catch let err as OpenAIDashboardBrowserCookieImporter.ImportError {
            switch err {
            case let .noMatchingAccount(found):
                let foundText: String = if found.isEmpty {
                    "no signed-in session detected in \(self.codexBrowserCookieOrder.loginHint)"
                } else {
                    found
                        .sorted { lhs, rhs in
                            if lhs.sourceLabel == rhs.sourceLabel { return lhs.email < rhs.email }
                            return lhs.sourceLabel < rhs.sourceLabel
                        }
                        .map { "\($0.sourceLabel): \($0.email)" }
                        .joined(separator: " • ")
                }
                self.logOpenAIWeb("[\(stamp)] import mismatch: \(foundText)")
                await MainActor.run {
                    self.openAIDashboardCookieImportStatus = allowAnyAccount
                        ? [
                            "No signed-in OpenAI web session found.",
                            "Found \(foundText).",
                        ].joined(separator: " ")
                        : [
                            "Browser cookies do not match Codex account (\(normalizedTarget ?? "unknown")).",
                            "Found \(foundText).",
                        ].joined(separator: " ")
                    // Treat mismatch like "not logged in" for the current Codex account.
                    self.openAIDashboardRequiresLogin = true
                    self.openAIDashboard = nil
                }
            case .noCookiesFound,
                 .browserAccessDenied,
                 .dashboardStillRequiresLogin,
                 .manualCookieHeaderInvalid:
                self.logOpenAIWeb("[\(stamp)] import failed: \(err.localizedDescription)")
                await MainActor.run {
                    self.openAIDashboardCookieImportStatus =
                        "OpenAI cookie import failed: \(err.localizedDescription)"
                    self.openAIDashboardRequiresLogin = true
                }
            }
        } catch {
            self.logOpenAIWeb("[\(stamp)] import failed: \(error.localizedDescription)")
            await MainActor.run {
                self.openAIDashboardCookieImportStatus =
                    "Browser cookie import failed: \(error.localizedDescription)"
            }
        }
        return nil
    }

    private func resetOpenAIWebDebugLog(context: String) {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        self.openAIWebDebugLines.removeAll(keepingCapacity: true)
        self.openAIDashboardCookieImportDebugLog = nil
        self.logOpenAIWeb("[\(stamp)] OpenAI web \(context) start")
    }

    private func logOpenAIWeb(_ message: String) {
        self.openAIWebLogger.debug(message)
        self.openAIWebDebugLines.append(message)
        if self.openAIWebDebugLines.count > 240 {
            self.openAIWebDebugLines.removeFirst(self.openAIWebDebugLines.count - 240)
        }
        self.openAIDashboardCookieImportDebugLog = self.openAIWebDebugLines.joined(separator: "\n")
    }

    private func dashboardEmailMismatch(expected: String?, actual: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return false }
        guard let raw = actual?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return false }
        return raw.lowercased() != expected.lowercased()
    }

    func codexAccountEmailForOpenAIDashboard() -> String? {
        let direct = self.snapshots[.codex]?.accountEmail(for: .codex)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct, !direct.isEmpty { return direct }
        let fallback = self.codexFetcher.loadAccountInfo().email?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback, !fallback.isEmpty { return fallback }
        let cached = self.openAIDashboard?.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached, !cached.isEmpty { return cached }
        let imported = self.lastOpenAIDashboardCookieImportEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let imported, !imported.isEmpty { return imported }
        return nil
    }
}

extension UsageStore {
    func debugDumpClaude() async {
        let output = await self.claudeFetcher.debugRawProbe(model: "sonnet")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codexbar-claude-probe.txt")
        try? output.write(to: url, atomically: true, encoding: .utf8)
        await MainActor.run {
            let snippet = String(output.prefix(180)).replacingOccurrences(of: "\n", with: " ")
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
                self.errors[provider] = "Failed to save log: \(error.localizedDescription)"
            }
            return nil
        }
    }

    func debugClaudeDump() async -> String {
        await ClaudeStatusProbe.latestDumps()
    }

    func debugAugmentDump() async -> String {
        await AugmentStatusProbe.latestDumps()
    }

    func debugLog(for provider: UsageProvider) async -> String {
        if let cached = self.probeLogs[provider], !cached.isEmpty {
            return cached
        }

        let claudeWebExtrasEnabled = self.settings.claudeWebExtrasEnabled
        let claudeUsageDataSource = self.settings.claudeUsageDataSource
        let claudeCookieSource = self.settings.claudeCookieSource
        let claudeCookieHeader = self.settings.claudeCookieHeader
        let cursorCookieSource = self.settings.cursorCookieSource
        let cursorCookieHeader = self.settings.cursorCookieHeader
        return await Task.detached(priority: .utility) { () -> String in
            switch provider {
            case .codex:
                let raw = await self.codexFetcher.debugRawRateLimits()
                await MainActor.run { self.probeLogs[.codex] = raw }
                return raw
            case .claude:
                let text = await self.debugClaudeLog(
                    claudeWebExtrasEnabled: claudeWebExtrasEnabled,
                    claudeUsageDataSource: claudeUsageDataSource,
                    claudeCookieSource: claudeCookieSource,
                    claudeCookieHeader: claudeCookieHeader)
                await MainActor.run { self.probeLogs[.claude] = text }
                return text
            case .zai:
                let resolution = ProviderTokenResolver.zaiResolution()
                let hasAny = resolution != nil
                let source = resolution?.source.rawValue ?? "none"
                let text = "Z_AI_API_KEY=\(hasAny ? "present" : "missing") source=\(source)"
                await MainActor.run { self.probeLogs[.zai] = text }
                return text
            case .gemini:
                let text = "Gemini debug log not yet implemented"
                await MainActor.run { self.probeLogs[.gemini] = text }
                return text
            case .antigravity:
                let text = "Antigravity debug log not yet implemented"
                await MainActor.run { self.probeLogs[.antigravity] = text }
                return text
            case .cursor:
                let text = await self.debugCursorLog(
                    cursorCookieSource: cursorCookieSource,
                    cursorCookieHeader: cursorCookieHeader)
                await MainActor.run { self.probeLogs[.cursor] = text }
                return text
            case .factory:
                let text = "Droid debug log not yet implemented"
                await MainActor.run { self.probeLogs[.factory] = text }
                return text
            case .copilot:
                let text = "Copilot debug log not yet implemented"
                await MainActor.run { self.probeLogs[.copilot] = text }
                return text
            case .minimax:
                let resolution = ProviderTokenResolver.minimaxResolution()
                let hasAny = resolution != nil
                let source = resolution?.source.rawValue ?? "none"
                let text = "MINIMAX_COOKIE=\(hasAny ? "present" : "missing") source=\(source)"
                await MainActor.run { self.probeLogs[.minimax] = text }
                return text
            case .vertexai:
                let text = "Vertex AI debug log not yet implemented"
                await MainActor.run { self.probeLogs[.vertexai] = text }
                return text
            case .kiro:
                let text = "Kiro debug log not yet implemented"
                await MainActor.run { self.probeLogs[.kiro] = text }
                return text
            case .augment:
                let text = await self.debugAugmentLog()
                await MainActor.run { self.probeLogs[.augment] = text }
                return text
            case .jetbrains:
                let text = "JetBrains AI debug log not yet implemented"
                await MainActor.run { self.probeLogs[.jetbrains] = text }
                return text
            }
        }.value
    }

    private func debugClaudeLog(
        claudeWebExtrasEnabled: Bool,
        claudeUsageDataSource: ClaudeUsageDataSource,
        claudeCookieSource: ProviderCookieSource,
        claudeCookieHeader: String) async -> String
    {
        await self.runWithTimeout(seconds: 15) {
            var lines: [String] = []
            let manualHeader = claudeCookieSource == .manual
                ? CookieHeaderNormalizer.normalize(claudeCookieHeader)
                : nil
            let hasKey = if let manualHeader {
                ClaudeWebAPIFetcher.hasSessionKey(cookieHeader: manualHeader)
            } else {
                ClaudeWebAPIFetcher.hasSessionKey(browserDetection: self.browserDetection) { msg in lines.append(msg) }
            }
            let hasOAuthCredentials = (try? ClaudeOAuthCredentialsStore.load()) != nil

            let strategy = ClaudeProviderDescriptor.resolveUsageStrategy(
                selectedDataSource: claudeUsageDataSource,
                webExtrasEnabled: claudeWebExtrasEnabled,
                hasWebSession: hasKey,
                hasOAuthCredentials: hasOAuthCredentials)

            lines.append("strategy=\(strategy.dataSource.rawValue)")
            lines.append("hasSessionKey=\(hasKey)")
            lines.append("hasOAuthCredentials=\(hasOAuthCredentials)")
            if strategy.useWebExtras {
                lines.append("web_extras=enabled")
            }
            lines.append("")

            switch strategy.dataSource {
            case .auto:
                lines.append("Auto source selected.")
                return lines.joined(separator: "\n")
            case .web:
                do {
                    let web = try await ClaudeWebAPIFetcher
                        .fetchUsage(browserDetection: self.browserDetection) { msg in lines.append(msg) }
                    lines.append("")
                    lines.append("Web API summary:")

                    let sessionReset = web.sessionResetsAt?.description ?? "nil"
                    lines.append("session_used=\(web.sessionPercentUsed)% resetsAt=\(sessionReset)")

                    if let weekly = web.weeklyPercentUsed {
                        let weeklyReset = web.weeklyResetsAt?.description ?? "nil"
                        lines.append("weekly_used=\(weekly)% resetsAt=\(weeklyReset)")
                    } else {
                        lines.append("weekly_used=nil")
                    }

                    lines.append("opus_used=\(web.opusPercentUsed?.description ?? "nil")")

                    if let extra = web.extraUsageCost {
                        let resetsAt = extra.resetsAt?.description ?? "nil"
                        let period = extra.period ?? "nil"
                        let line =
                            "extra_usage used=\(extra.used) limit=\(extra.limit) " +
                            "currency=\(extra.currencyCode) period=\(period) resetsAt=\(resetsAt)"
                        lines.append(line)
                    } else {
                        lines.append("extra_usage=nil")
                    }

                    return lines.joined(separator: "\n")
                } catch {
                    lines.append("Web API failed: \(error.localizedDescription)")
                    return lines.joined(separator: "\n")
                }
            case .cli:
                let cli = await self.claudeFetcher.debugRawProbe(model: "sonnet")
                lines.append(cli)
                return lines.joined(separator: "\n")
            case .oauth:
                lines.append("OAuth source selected.")
                return lines.joined(separator: "\n")
            }
        }
    }

    private func debugCursorLog(
        cursorCookieSource: ProviderCookieSource,
        cursorCookieHeader: String) async -> String
    {
        await self.runWithTimeout(seconds: 15) {
            var lines: [String] = []

            do {
                let probe = CursorStatusProbe(browserDetection: self.browserDetection)
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

    private func debugAugmentLog() async -> String {
        await self.runWithTimeout(seconds: 15) {
            let probe = AugmentStatusProbe()
            return await probe.debugRawProbe()
        }
    }

    private func runWithTimeout(seconds: Double, operation: @escaping @Sendable () async -> String) async -> String {
        await withTaskGroup(of: String?.self) { group -> String in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next()?.flatMap(\.self)
            group.cancelAll()
            return result ?? "Probe timed out after \(Int(seconds))s"
        }
    }

    private func detectVersions() {
        Task.detached { [claudeFetcher] in
            let codexVer = Self.readCLI("codex", args: ["-s", "read-only", "-a", "untrusted", "--version"])
            let claudeVer = claudeFetcher.detectVersion()
            let geminiVer = Self.readCLI("gemini", args: ["--version"])
            let antigravityVer = await AntigravityStatusProbe.detectVersion()
            let kiroVer = KiroStatusProbe.detectVersion()
            await MainActor.run {
                self.codexVersion = codexVer
                self.claudeVersion = claudeVer
                self.geminiVersion = geminiVer
                self.zaiVersion = nil
                self.antigravityVersion = antigravityVer
                self.kiroVersion = kiroVer
            }
        }
    }

    private nonisolated static func readCLI(_ cmd: String, args: [String]) -> String? {
        let env = ProcessInfo.processInfo.environment
        var pathEnv = env
        pathEnv["PATH"] = PathBuilder.effectivePATH(purposes: [.rpc, .tty, .nodeTooling], env: env)
        let loginPATH = LoginShellPathCache.shared.current

        let resolved: String = switch cmd {
        case "codex":
            BinaryLocator.resolveCodexBinary(env: env, loginPATH: loginPATH) ?? cmd
        case "gemini":
            BinaryLocator.resolveGeminiBinary(env: env, loginPATH: loginPATH) ?? cmd
        default:
            cmd
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [resolved] + args
        process.environment = pathEnv
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else { return nil }
        return text
    }

    private func refreshPathDebugInfo() {
        self.pathDebugInfo = PathBuilder.debugSnapshot(purposes: [.rpc, .tty, .nodeTooling])
    }

    func clearCostUsageCache() async -> String? {
        let errorMessage: String? = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let cacheDirs = [
                Self.costUsageCacheDirectory(fileManager: fm),
            ]

            for cacheDir in cacheDirs {
                do {
                    try fm.removeItem(at: cacheDir)
                } catch let error as NSError {
                    if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError { continue }
                    return error.localizedDescription
                }
            }
            return nil
        }.value

        guard errorMessage == nil else { return errorMessage }

        self.tokenSnapshots.removeAll()
        self.tokenErrors.removeAll()
        self.lastTokenFetchAt.removeAll()
        self.tokenFailureGates[.codex]?.reset()
        self.tokenFailureGates[.claude]?.reset()
        return nil
    }

    private func refreshTokenUsage(_ provider: UsageProvider, force: Bool) async {
        guard provider == .codex || provider == .claude || provider == .vertexai else {
            self.tokenSnapshots.removeValue(forKey: provider)
            self.tokenErrors[provider] = nil
            self.tokenFailureGates[provider]?.reset()
            self.lastTokenFetchAt.removeValue(forKey: provider)
            return
        }

        guard self.settings.costUsageEnabled else {
            self.tokenSnapshots.removeValue(forKey: provider)
            self.tokenErrors[provider] = nil
            self.tokenFailureGates[provider]?.reset()
            self.lastTokenFetchAt.removeValue(forKey: provider)
            return
        }

        guard self.isEnabled(provider) else {
            self.tokenSnapshots.removeValue(forKey: provider)
            self.tokenErrors[provider] = nil
            self.tokenFailureGates[provider]?.reset()
            self.lastTokenFetchAt.removeValue(forKey: provider)
            return
        }

        guard !self.tokenRefreshInFlight.contains(provider) else { return }

        let now = Date()
        if !force,
           let last = self.lastTokenFetchAt[provider],
           now.timeIntervalSince(last) < self.tokenFetchTTL
        {
            return
        }
        self.lastTokenFetchAt[provider] = now
        self.tokenRefreshInFlight.insert(provider)
        defer { self.tokenRefreshInFlight.remove(provider) }

        let startedAt = Date()
        let providerText = provider.rawValue
        self.tokenCostLogger
            .debug("cost usage start provider=\(providerText) force=\(force)")

        do {
            let fetcher = self.costUsageFetcher
            let timeoutSeconds = self.tokenFetchTimeout
            let snapshot = try await withThrowingTaskGroup(of: CostUsageTokenSnapshot.self) { group in
                group.addTask(priority: .utility) {
                    try await fetcher.loadTokenSnapshot(
                        provider: provider,
                        now: now,
                        forceRefresh: force,
                        allowVertexClaudeFallback: !self.isEnabled(.claude))
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    throw CostUsageError.timedOut(seconds: Int(timeoutSeconds))
                }
                defer { group.cancelAll() }
                guard let snapshot = try await group.next() else { throw CancellationError() }
                return snapshot
            }

            guard !snapshot.daily.isEmpty else {
                self.tokenSnapshots.removeValue(forKey: provider)
                self.tokenErrors[provider] = Self.tokenCostNoDataMessage(for: provider)
                self.tokenFailureGates[provider]?.recordSuccess()
                return
            }
            let duration = Date().timeIntervalSince(startedAt)
            let sessionCost = snapshot.sessionCostUSD.map(UsageFormatter.usdString) ?? "—"
            let monthCost = snapshot.last30DaysCostUSD.map(UsageFormatter.usdString) ?? "—"
            let durationText = String(format: "%.2f", duration)
            let message =
                "cost usage success provider=\(providerText) " +
                "duration=\(durationText)s " +
                "today=\(sessionCost) " +
                "30d=\(monthCost)"
            self.tokenCostLogger.info(message)
            self.tokenSnapshots[provider] = snapshot
            self.tokenErrors[provider] = nil
            self.tokenFailureGates[provider]?.recordSuccess()
            self.persistWidgetSnapshot(reason: "token-usage")
        } catch {
            if error is CancellationError { return }
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
