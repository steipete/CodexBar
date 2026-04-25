import AppKit
import CodexBarCore
import Observation
import QuartzCore
import SwiftUI

// MARK: - Status item controller (AppKit-hosted icons, SwiftUI popovers)

@MainActor
protocol StatusItemControlling: AnyObject {
    func openMenuFromShortcut()
    func celebrationOriginPoint(for provider: UsageProvider?) -> CGPoint?
}

extension StatusItemControlling {
    func celebrationOriginPoint(for provider: UsageProvider?) -> CGPoint? {
        nil
    }
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, StatusItemControlling {
    // Disable SwiftUI menu cards + menu refresh work in tests to avoid swiftpm-testing-helper crashes.
    static var menuCardRenderingEnabled = !SettingsStore.isRunningTests
    static var menuRefreshEnabled = !SettingsStore.isRunningTests
    typealias Factory = @MainActor (
        UsageStore,
        SettingsStore,
        AccountInfo,
        UpdaterProviding,
        PreferencesSelection,
        ManagedCodexAccountCoordinator,
        CodexAccountPromotionCoordinator)
        -> StatusItemControlling
    // swiftlint:disable:next function_parameter_count
    static func makeDefaultController(
        store: UsageStore,
        settings: SettingsStore,
        account: AccountInfo,
        updater: UpdaterProviding,
        selection: PreferencesSelection,
        managedCodexAccountCoordinator: ManagedCodexAccountCoordinator,
        codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator)
        -> StatusItemControlling
    {
        StatusItemController(
            store: store,
            settings: settings,
            account: account,
            updater: updater,
            preferencesSelection: selection,
            managedCodexAccountCoordinator: managedCodexAccountCoordinator,
            codexAccountPromotionCoordinator: codexAccountPromotionCoordinator)
    }

    static let defaultFactory: Factory = StatusItemController.makeDefaultController

    static var factory: Factory = StatusItemController.defaultFactory

    let store: UsageStore
    let settings: SettingsStore
    let account: AccountInfo
    let updater: UpdaterProviding
    let managedCodexAccountCoordinator: ManagedCodexAccountCoordinator
    let codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator
    private let statusBar: NSStatusBar
    var statusItem: NSStatusItem
    var statusItems: [UsageProvider: NSStatusItem] = [:]
    var lastMenuProvider: UsageProvider?
    var menuProviders: [ObjectIdentifier: UsageProvider] = [:]
    var menuContentVersion: Int = 0
    var menuVersions: [ObjectIdentifier: Int] = [:]
    var mergedMenu: NSMenu?
    var providerMenus: [UsageProvider: NSMenu] = [:]
    var fallbackMenu: NSMenu?
    var openMenus: [ObjectIdentifier: NSMenu] = [:]
    var menuRefreshTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    #if DEBUG
    var _test_openMenuRefreshYieldOverride: (@MainActor () async -> Void)?
    var _test_openMenuRebuildObserver: (@MainActor (NSMenu) -> Void)?
    var _test_codexAmbientLoginRunnerOverride: (@MainActor (TimeInterval) async -> CodexLoginRunner.Result)?
    #endif
    var blinkTask: Task<Void, Never>?
    var loginTask: Task<Void, Never>? {
        didSet { self.refreshMenusForLoginStateChange() }
    }

    var creditsPurchaseWindow: OpenAICreditsPurchaseWindowController?

    var activeLoginProvider: UsageProvider? {
        didSet {
            if oldValue != self.activeLoginProvider {
                self.refreshMenusForLoginStateChange()
            }
        }
    }

    var blinkStates: [UsageProvider: BlinkState] = [:]
    var blinkAmounts: [UsageProvider: CGFloat] = [:]
    var wiggleAmounts: [UsageProvider: CGFloat] = [:]
    var tiltAmounts: [UsageProvider: CGFloat] = [:]
    var blinkForceUntil: Date?
    var loginPhase: LoginPhase = .idle {
        didSet {
            if oldValue != self.loginPhase {
                self.refreshMenusForLoginStateChange()
            }
        }
    }

    let preferencesSelection: PreferencesSelection
    var animationDriver: DisplayLinkDriver?
    var animationPhase: Double = 0
    var animationPattern: LoadingPattern = .knightRider
    private var lastConfigRevision: Int
    private var lastProviderOrder: [UsageProvider]
    private var lastMergeIcons: Bool
    private var lastSwitcherShowsIcons: Bool
    private var lastObservedUsageBarsShowUsed: Bool
    /// Tracks which `usageBarsShowUsed` mode the provider switcher was built with.
    /// Used to decide whether we can "smart update" menu content without rebuilding the switcher.
    var lastSwitcherUsageBarsShowUsed: Bool
    /// Tracks whether the merged-menu switcher was built with the Overview tab visible.
    /// Used to force switcher rebuilds when Overview availability toggles.
    var lastSwitcherIncludesOverview: Bool = false
    /// Tracks which providers the merged menu's switcher was built with, to detect when it needs full rebuild.
    var lastSwitcherProviders: [UsageProvider] = []
    /// Tracks which switcher tab state was used for the current merged-menu switcher instance.
    var lastMergedSwitcherSelection: ProviderSwitcherSelection?
    /// Tracks the visible Codex account switcher contents for merged-menu smart updates.
    var lastCodexAccountMenuDisplay: CodexAccountMenuDisplay?
    var lastAppliedMergedIconRenderSignature: String?
    let loginLogger = CodexBarLog.logger(LogCategories.login)
    var selectedMenuProvider: UsageProvider? {
        get { self.settings.selectedMenuProvider }
        set { self.settings.selectedMenuProvider = newValue }
    }

    struct BlinkState {
        var nextBlink: Date
        var blinkStart: Date?
        var pendingSecondStart: Date?
        var effect: MotionEffect = .blink

        static func randomDelay() -> TimeInterval {
            Double.random(in: 3...12)
        }
    }

    enum MotionEffect {
        case blink
        case wiggle
        case tilt
    }

    enum LoginPhase {
        case idle
        case requesting
        case waitingBrowser
    }

    func menuBarMetricWindow(for provider: UsageProvider, snapshot: UsageSnapshot?) -> RateWindow? {
        if provider == .codex {
            return self.codexMenuBarMetricWindow(snapshot: snapshot)
        }
        return MenuBarMetricWindowResolver.rateWindow(
            preference: self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot),
            provider: provider,
            snapshot: snapshot,
            supportsAverage: self.settings.menuBarMetricSupportsAverage(for: provider))
    }

    private func codexMenuBarMetricWindow(snapshot: UsageSnapshot?) -> RateWindow? {
        guard let snapshot else { return nil }
        let projection = CodexConsumerProjection.make(
            surface: .menuBar,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: self.store.credits,
                rawCreditsError: self.store.lastCreditsError,
                liveDashboard: self.store.openAIDashboard,
                rawDashboardError: self.store.lastOpenAIDashboardError,
                dashboardAttachmentAuthorized: self.store.openAIDashboardAttachmentAuthorized,
                dashboardRequiresLogin: self.store.openAIDashboardRequiresLogin,
                now: snapshot.updatedAt))
        let lanes = projection.visibleRateLanes
        let first = lanes.first.flatMap { projection.rateWindow(for: $0) }
        let second = lanes.dropFirst().first.flatMap { projection.rateWindow(for: $0) }
        let preference = self.settings.menuBarMetricPreference(for: .codex, snapshot: snapshot)

        switch preference {
        case .secondary, .tertiary:
            return second ?? first
        case .extraUsage:
            return first
        case .average:
            guard self.settings.menuBarMetricSupportsAverage(for: .codex),
                  let primary = first,
                  let secondary = second
            else {
                return first
            }
            let usedPercent = (primary.usedPercent + secondary.usedPercent) / 2
            return RateWindow(usedPercent: usedPercent, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        case .automatic, .primary:
            return first
        }
    }

    init(
        store: UsageStore,
        settings: SettingsStore,
        account: AccountInfo,
        updater: UpdaterProviding,
        preferencesSelection: PreferencesSelection,
        managedCodexAccountCoordinator: ManagedCodexAccountCoordinator = ManagedCodexAccountCoordinator(),
        codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator? = nil,
        statusBar: NSStatusBar = .system,
        observeProviderConfigNotifications: Bool = !SettingsStore.isRunningTests)
    {
        if SettingsStore.isRunningTests {
            _ = NSApplication.shared
        }
        self.store = store
        self.settings = settings
        self.account = account
        self.updater = updater
        self.preferencesSelection = preferencesSelection
        self.managedCodexAccountCoordinator = managedCodexAccountCoordinator
        self.codexAccountPromotionCoordinator = codexAccountPromotionCoordinator
            ?? CodexAccountPromotionCoordinator(
                settingsStore: settings,
                usageStore: store,
                managedAccountCoordinator: managedCodexAccountCoordinator)
        self.lastConfigRevision = settings.configRevision
        self.lastProviderOrder = settings.providerOrder
        self.lastMergeIcons = settings.mergeIcons
        self.lastSwitcherShowsIcons = settings.switcherShowsIcons
        self.lastObservedUsageBarsShowUsed = settings.usageBarsShowUsed
        self.lastSwitcherUsageBarsShowUsed = settings.usageBarsShowUsed
        self.statusBar = statusBar
        let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        // Ensure the icon is rendered at 1:1 without resampling (crisper edges for template images).
        item.button?.imageScaling = .scaleNone
        self.statusItem = item
        // Status items for individual providers are now created lazily in updateVisibility()
        super.init()
        self.wireBindings()
        self.updateVisibility()
        self.updateIcons()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.handleDebugReplayNotification(_:)),
            name: .codexbarDebugReplayAllAnimations,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.handleDebugBlinkNotification),
            name: .codexbarDebugBlinkNow,
            object: nil)
        if observeProviderConfigNotifications {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.handleProviderConfigDidChange),
                name: .codexbarProviderConfigDidChange,
                object: nil)
        }
    }

    convenience init(
        store: UsageStore,
        settings: SettingsStore,
        account: AccountInfo,
        updater: UpdaterProviding,
        preferencesSelection: PreferencesSelection,
        statusBar: NSStatusBar = .system,
        observeProviderConfigNotifications: Bool = !SettingsStore.isRunningTests)
    {
        self.init(
            store: store,
            settings: settings,
            account: account,
            updater: updater,
            preferencesSelection: preferencesSelection,
            managedCodexAccountCoordinator: ManagedCodexAccountCoordinator(),
            codexAccountPromotionCoordinator: nil,
            statusBar: statusBar,
            observeProviderConfigNotifications: observeProviderConfigNotifications)
    }

    private func wireBindings() {
        self.observeStoreChanges()
        self.observeStoreIconChanges()
        self.observeDebugForceAnimation()
        self.observeSettingsChanges()
        self.observeUpdaterChanges()
        self.observeManagedCodexCoordinatorChanges()
    }

    private func observeStoreChanges() {
        withObservationTracking {
            _ = self.store.menuObservationToken
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeStoreChanges()
                self.invalidateMenus()
            }
        }
    }

    private func observeStoreIconChanges() {
        withObservationTracking {
            _ = self.store.iconObservationToken
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeStoreIconChanges()
                self.updateIcons()
            }
        }
    }

    private func observeDebugForceAnimation() {
        withObservationTracking {
            _ = self.store.debugForceAnimation
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeDebugForceAnimation()
                self.updateVisibility()
                self.updateBlinkingState()
            }
        }
    }

    private func observeSettingsChanges() {
        withObservationTracking {
            _ = self.settings.menuObservationToken
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeSettingsChanges()
                self.handleSettingsChange(reason: "observation")
            }
        }
    }

    func handleProviderConfigChange(reason: String) {
        self.handleSettingsChange(reason: "config:\(reason)")
    }

    @objc private func handleProviderConfigDidChange(_ notification: Notification) {
        let reason = notification.userInfo?["reason"] as? String ?? "unknown"
        if let source = notification.object as? SettingsStore,
           source !== self.settings
        {
            if let config = notification.userInfo?["config"] as? CodexBarConfig {
                self.settings.applyExternalConfig(config, reason: "external-\(reason)")
            } else {
                self.settings.reloadConfig(reason: "external-\(reason)")
            }
        }
        self.handleProviderConfigChange(reason: "notification:\(reason)")
    }

    private func observeUpdaterChanges() {
        withObservationTracking {
            _ = self.updater.updateStatus.isUpdateReady
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeUpdaterChanges()
                self.invalidateMenus()
            }
        }
    }

    private func observeManagedCodexCoordinatorChanges() {
        withObservationTracking {
            _ = self.managedCodexAccountCoordinator.isAuthenticatingManagedAccount
            _ = self.managedCodexAccountCoordinator.authenticatingManagedAccountID
            _ = self.managedCodexAccountCoordinator.isRemovingManagedAccount
            _ = self.managedCodexAccountCoordinator.removingManagedAccountID
            _ = self.codexAccountPromotionCoordinator.isAuthenticatingLiveAccount
            _ = self.codexAccountPromotionCoordinator.isPromotingSystemAccount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeManagedCodexCoordinatorChanges()
                self.refreshMenusForLoginStateChange()
            }
        }
    }

    private func invalidateMenus() {
        self.menuContentVersion &+= 1
        // Don't refresh menus while they're open - wait until they close and reopen
        // This prevents expensive rebuilds while user is navigating the menu
        guard self.openMenus.isEmpty else { return }
        self.refreshOpenMenusIfNeeded()
        Task { @MainActor in
            // AppKit can ignore menu mutations while tracking; retry on the next run loop.
            await Task.yield()
            guard self.openMenus.isEmpty else { return }
            self.refreshOpenMenusIfNeeded()
        }
    }

    private func shouldRefreshOpenMenusForProviderSwitcher() -> Bool {
        var shouldRefresh = false
        let revision = self.settings.configRevision
        if revision != self.lastConfigRevision {
            self.lastConfigRevision = revision
            shouldRefresh = true
        }
        let order = self.settings.providerOrder
        if order != self.lastProviderOrder {
            self.lastProviderOrder = order
            shouldRefresh = true
        }
        let mergeIcons = self.settings.mergeIcons
        if mergeIcons != self.lastMergeIcons {
            self.lastMergeIcons = mergeIcons
            shouldRefresh = true
        }
        let showsIcons = self.settings.switcherShowsIcons
        if showsIcons != self.lastSwitcherShowsIcons {
            self.lastSwitcherShowsIcons = showsIcons
            shouldRefresh = true
        }
        let usageBarsShowUsed = self.settings.usageBarsShowUsed
        if usageBarsShowUsed != self.lastObservedUsageBarsShowUsed {
            self.lastObservedUsageBarsShowUsed = usageBarsShowUsed
            shouldRefresh = true
        }
        return shouldRefresh
    }

    private func handleSettingsChange(reason: String) {
        let configChanged = self.settings.configRevision != self.lastConfigRevision
        let orderChanged = self.settings.providerOrder != self.lastProviderOrder
        let shouldRefreshOpenMenus = self.shouldRefreshOpenMenusForProviderSwitcher()
        self.invalidateMenus()
        if orderChanged || configChanged {
            self.rebuildProviderStatusItems()
        }
        self.updateVisibility()
        self.updateIcons()
        if shouldRefreshOpenMenus {
            self.refreshOpenMenusIfNeeded()
        }
    }

    private func updateIcons() {
        // Avoid flicker: when an animation driver is active, store updates can call `updateIcons()` and
        // briefly overwrite the animated frame with the static (phase=nil) icon.
        let phase: Double? = self.needsMenuBarIconAnimation() ? self.animationPhase : nil
        if self.shouldMergeIcons {
            let skippedMergedRender = self.applyIcon(phase: phase)
            if skippedMergedRender,
               let mergedMenu = self.mergedMenu,
               self.statusItem.menu === mergedMenu
            {
                return
            }
            self.attachMenus()
        } else {
            UsageProvider.allCases.forEach { self.applyIcon(for: $0, phase: phase) }
            self.attachMenus(fallback: self.fallbackProvider)
        }
        self.updateAnimationState()
        self.updateBlinkingState()
    }

    /// Lazily retrieves or creates a status item for the given provider
    func lazyStatusItem(for provider: UsageProvider) -> NSStatusItem {
        if let existing = self.statusItems[provider] {
            return existing
        }
        let item = self.statusBar.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imageScaling = .scaleNone
        self.statusItems[provider] = item
        return item
    }

    private func updateVisibility() {
        let anyEnabled = !self.store.enabledProvidersForDisplay().isEmpty
        let force = self.store.debugForceAnimation
        let mergeIcons = self.shouldMergeIcons
        if mergeIcons {
            self.statusItem.isVisible = anyEnabled || force
            for item in self.statusItems.values {
                item.isVisible = false
            }
            self.attachMenus()
        } else {
            self.statusItem.isVisible = false
            let fallback = self.fallbackProvider
            for provider in UsageProvider.allCases {
                let isEnabled = self.isEnabled(provider)
                let shouldBeVisible = isEnabled || fallback == provider || force
                if shouldBeVisible {
                    let item = self.lazyStatusItem(for: provider)
                    item.isVisible = true
                } else if let item = self.statusItems[provider] {
                    item.isVisible = false
                }
            }
            self.attachMenus(fallback: fallback)
        }
        self.updateAnimationState()
        self.updateBlinkingState()
    }

    var fallbackProvider: UsageProvider? {
        // Intentionally uses availability-filtered list: fallback activates when no provider
        // can actually work, ensuring at least a codex icon is always visible.
        self.store.enabledProviders().isEmpty ? .codex : nil
    }

    func isEnabled(_ provider: UsageProvider) -> Bool {
        self.store.isEnabled(provider)
    }

    private func refreshMenusForLoginStateChange() {
        self.invalidateMenus()
        if self.shouldMergeIcons {
            self.attachMenus()
        } else {
            self.attachMenus(fallback: self.fallbackProvider)
        }
    }

    private func attachMenus() {
        if self.mergedMenu == nil {
            self.mergedMenu = self.makeMenu()
        }
        if self.statusItem.menu !== self.mergedMenu {
            self.statusItem.menu = self.mergedMenu
        }
    }

    private func attachMenus(fallback: UsageProvider? = nil) {
        for provider in UsageProvider.allCases {
            // Only access/create the status item if it's actually needed
            let shouldHaveItem = self.isEnabled(provider) || fallback == provider

            if shouldHaveItem {
                let item = self.lazyStatusItem(for: provider)

                if self.isEnabled(provider) {
                    if self.providerMenus[provider] == nil {
                        self.providerMenus[provider] = self.makeMenu(for: provider)
                    }
                    let menu = self.providerMenus[provider]
                    if item.menu !== menu {
                        item.menu = menu
                    }
                } else if fallback == provider {
                    if self.fallbackMenu == nil {
                        self.fallbackMenu = self.makeMenu(for: nil)
                    }
                    if item.menu !== self.fallbackMenu {
                        item.menu = self.fallbackMenu
                    }
                }
            } else if let item = self.statusItems[provider] {
                // Item exists but is no longer needed - clear its menu
                if item.menu != nil {
                    item.menu = nil
                }
            }
        }
    }

    private func rebuildProviderStatusItems() {
        for item in self.statusItems.values {
            self.statusBar.removeStatusItem(item)
        }
        self.statusItems.removeAll(keepingCapacity: true)

        for provider in self.settings.orderedProviders() {
            let item = self.statusBar.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.imageScaling = .scaleNone
            self.statusItems[provider] = item
        }
    }

    func isVisible(_ provider: UsageProvider) -> Bool {
        self.store.debugForceAnimation || self.isEnabled(provider) || self.fallbackProvider == provider
    }

    var shouldMergeIcons: Bool {
        self.settings.mergeIcons && self.store.enabledProvidersForDisplay().count > 1
    }

    func switchAccountSubtitle(for target: UsageProvider) -> String? {
        guard self.loginTask != nil, let provider = self.activeLoginProvider, provider == target else { return nil }
        let base: String
        switch self.loginPhase {
        case .idle: return nil
        case .requesting: base = "Requesting login…"
        case .waitingBrowser: base = "Waiting in browser…"
        }
        let prefix = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        return "\(prefix): \(base)"
    }

    deinit {
        let animationDriver = self.animationDriver
        Task { @MainActor in
            animationDriver?.stop()
        }
        self.blinkTask?.cancel()
        self.loginTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}
