import AppKit
import CodexBarCore
import Observation
import QuartzCore
import SwiftUI

// MARK: - Status item controller (AppKit-hosted icons, SwiftUI popovers)

protocol StatusItemControlling: AnyObject {}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, StatusItemControlling {
    typealias Factory = (UsageStore, SettingsStore, AccountInfo, UpdaterProviding, PreferencesSelection)
        -> StatusItemControlling
    static let defaultFactory: Factory = { store, settings, account, updater, selection in
        StatusItemController(
            store: store,
            settings: settings,
            account: account,
            updater: updater,
            preferencesSelection: selection)
    }

    static var factory: Factory = StatusItemController.defaultFactory

    let store: UsageStore
    let settings: SettingsStore
    let account: AccountInfo
    let updater: UpdaterProviding
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
    var animationDisplayLink: CADisplayLink?
    var animationPhase: Double = 0
    var animationPattern: LoadingPattern = .knightRider
    let loginLogger = CodexBarLog.logger("login")
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

    init(
        store: UsageStore,
        settings: SettingsStore,
        account: AccountInfo,
        updater: UpdaterProviding,
        preferencesSelection: PreferencesSelection)
    {
        self.store = store
        self.settings = settings
        self.account = account
        self.updater = updater
        self.preferencesSelection = preferencesSelection
        let bar = NSStatusBar.system
        let item = bar.statusItem(withLength: NSStatusItem.variableLength)
        // Ensure the icon is rendered at 1:1 without resampling (crisper edges for template images).
        item.button?.imageScaling = .scaleNone
        self.statusItem = item
        for provider in UsageProvider.allCases {
            let providerItem = bar.statusItem(withLength: NSStatusItem.variableLength)
            // Ensure the icon is rendered at 1:1 without resampling (crisper edges for template images).
            providerItem.button?.imageScaling = .scaleNone
            self.statusItems[provider] = providerItem
        }
        super.init()
        self.wireBindings()
        self.updateIcons()
        self.updateVisibility()
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
    }

    private func wireBindings() {
        self.observeStoreChanges()
        self.observeDebugForceAnimation()
        self.observeSettingsChanges()
        self.observeUpdaterChanges()
    }

    private func observeStoreChanges() {
        withObservationTracking {
            _ = self.store.menuObservationToken
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeStoreChanges()
                self.invalidateMenus()
                self.updateIcons()
                self.updateBlinkingState()
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
                self.invalidateMenus()
                self.updateVisibility()
                self.updateIcons()
            }
        }
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

    private func invalidateMenus() {
        self.menuContentVersion &+= 1
        self.refreshOpenMenusIfNeeded()
        Task { @MainActor in
            // AppKit can ignore menu mutations while tracking; retry on the next run loop.
            await Task.yield()
            self.refreshOpenMenusIfNeeded()
        }
    }

    private func updateIcons() {
        if self.shouldMergeIcons {
            self.applyIcon(phase: nil)
            self.attachMenus()
        } else {
            UsageProvider.allCases.forEach { self.applyIcon(for: $0, phase: nil) }
            self.attachMenus(fallback: self.fallbackProvider)
        }
        self.updateAnimationState()
        self.updateBlinkingState()
    }

    private func updateVisibility() {
        let anyEnabled = !self.store.enabledProviders().isEmpty
        let force = self.store.debugForceAnimation
        if self.shouldMergeIcons {
            self.statusItem.isVisible = anyEnabled || force
            for item in self.statusItems.values {
                item.isVisible = false
            }
            self.attachMenus()
        } else {
            self.statusItem.isVisible = false
            let fallback = self.fallbackProvider
            for provider in UsageProvider.allCases {
                let item = self.statusItems[provider]
                let isEnabled = self.isEnabled(provider)
                item?.isVisible = isEnabled || fallback == provider || force
            }
            self.attachMenus(fallback: fallback)
        }
        self.updateAnimationState()
        self.updateBlinkingState()
    }

    var fallbackProvider: UsageProvider? {
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
        self.statusItem.menu = self.mergedMenu
    }

    private func attachMenus(fallback: UsageProvider? = nil) {
        for provider in UsageProvider.allCases {
            guard let item = self.statusItems[provider] else { continue }
            if self.isEnabled(provider) {
                if self.providerMenus[provider] == nil {
                    self.providerMenus[provider] = self.makeMenu(for: provider)
                }
                item.menu = self.providerMenus[provider]
            } else if fallback == provider {
                if self.fallbackMenu == nil {
                    self.fallbackMenu = self.makeMenu(for: nil)
                }
                item.menu = self.fallbackMenu
            } else {
                item.menu = nil
            }
        }
    }

    func isVisible(_ provider: UsageProvider) -> Bool {
        self.store.debugForceAnimation || self.isEnabled(provider) || self.fallbackProvider == provider
    }

    var shouldMergeIcons: Bool {
        self.settings.mergeIcons && self.store.enabledProviders().count > 1
    }

    func switchAccountSubtitle(for target: UsageProvider) -> String? {
        guard self.loginTask != nil, let provider = self.activeLoginProvider, provider == target else { return nil }
        let base: String
        switch self.loginPhase {
        case .idle: return nil
        case .requesting: base = "Requesting login…"
        case .waitingBrowser: base = "Waiting in browser…"
        }
        let prefix = switch provider {
        case .codex: "Codex"
        case .claude: "Claude"
        case .zai: "z.ai"
        case .gemini: "Gemini"
        case .antigravity: "Antigravity"
        case .cursor: "Cursor"
        case .factory: "Factory"
        }
        return "\(prefix): \(base)"
    }

    deinit {
        self.blinkTask?.cancel()
        self.loginTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}
