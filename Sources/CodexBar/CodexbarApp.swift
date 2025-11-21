import AppKit
import Combine
import QuartzCore
import Security
import SwiftUI

@main
struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = SettingsStore()
    @StateObject private var store: UsageStore
    private let preferencesSelection = PreferencesSelection()
    private let account: AccountInfo

    init() {
        let settings = SettingsStore()
        let fetcher = UsageFetcher()
        self.account = fetcher.loadAccountInfo()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: UsageStore(fetcher: fetcher, settings: settings))
        self.appDelegate.configure(
            store: _store.wrappedValue,
            settings: settings,
            account: self.account,
            selection: self.preferencesSelection)
    }

    @SceneBuilder
    var body: some Scene {
        // Hidden 1×1 window to keep SwiftUI's lifecycle alive so `Settings` scene
        // shows the native toolbar tabs even though the UI is AppKit-based.
        WindowGroup("CodexBarLifecycleKeepalive") {
            HiddenWindowView()
        }
        .defaultSize(width: 1, height: 1)
        .windowStyle(.hiddenTitleBar)

        Settings {
            PreferencesView(
                settings: self.settings,
                store: self.store,
                updater: self.appDelegate.updaterController,
                selection: self.preferencesSelection)
        }
        .defaultSize(width: PreferencesTab.windowWidth, height: PreferencesTab.general.preferredHeight)
        .windowResizability(.contentSize)
    }

    private func openSettings(tab: PreferencesTab) {
        self.preferencesSelection.tab = tab
        NSApp.activate(ignoringOtherApps: true)
        _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

// MARK: - Updater abstraction

@MainActor
protocol UpdaterProviding: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var isAvailable: Bool { get }
    func checkForUpdates(_ sender: Any?)
}

// No-op updater used for debug builds and non-bundled runs to suppress Sparkle dialogs.
final class DisabledUpdaterController: UpdaterProviding {
    var automaticallyChecksForUpdates: Bool = false
    let isAvailable: Bool = false
    func checkForUpdates(_ sender: Any?) {}
}

#if canImport(Sparkle) && ENABLE_SPARKLE
import Sparkle

extension SPUStandardUpdaterController: UpdaterProviding {
    var automaticallyChecksForUpdates: Bool {
        get { self.updater.automaticallyChecksForUpdates }
        set { self.updater.automaticallyChecksForUpdates = newValue }
    }

    var isAvailable: Bool { true }
}

private func isDeveloperIDSigned(bundleURL: URL) -> Bool {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
          let code = staticCode else { return false }

    var infoCF: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
          let info = infoCF as? [String: Any],
          let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certs.first else { return false }

    if let summary = SecCertificateCopySubjectSummary(leaf) as String? {
        return summary.hasPrefix("Developer ID Application:")
    }
    return false
}

private func makeUpdaterController() -> UpdaterProviding {
    let bundleURL = Bundle.main.bundleURL
    let isBundledApp = bundleURL.pathExtension == "app"
    guard isBundledApp, isDeveloperIDSigned(bundleURL: bundleURL) else { return DisabledUpdaterController() }

    let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil)
    controller.updater.automaticallyChecksForUpdates = false
    controller.startUpdater()
    return controller
}
#else
private func makeUpdaterController() -> UpdaterProviding {
    DisabledUpdaterController()
}
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updaterController: UpdaterProviding = makeUpdaterController()
    private var statusController: StatusItemController?
    private var store: UsageStore?
    private var settings: SettingsStore?
    private var account: AccountInfo?
    private var preferencesSelection: PreferencesSelection?

    func configure(store: UsageStore, settings: SettingsStore, account: AccountInfo, selection: PreferencesSelection) {
        self.store = store
        self.settings = settings
        self.account = account
        self.preferencesSelection = selection
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.ensureStatusController()
    }

    private func ensureStatusController() {
        if self.statusController != nil {
            return
        }

        if let store = self.store,
           let settings = self.settings,
           let account = self.account,
           let selection = self.preferencesSelection {
            self.statusController = StatusItemController(
                store: store,
                settings: settings,
                account: account,
                updater: self.updaterController,
                preferencesSelection: selection)
        } else {
            let settings = SettingsStore()
            let fetcher = UsageFetcher()
            let account = fetcher.loadAccountInfo()
            let store = UsageStore(fetcher: fetcher, settings: settings)
            self.statusController = StatusItemController(
                store: store,
                settings: settings,
                account: account,
                updater: self.updaterController,
                preferencesSelection: PreferencesSelection())
        }
    }
}

extension CodexBarApp {
    private var codexSnapshot: UsageSnapshot? { self.store.snapshot(for: .codex) }
    private var claudeSnapshot: UsageSnapshot? { self.store.snapshot(for: .claude) }
    private var codexShouldAnimate: Bool {
        self.store.isEnabled(.codex) && self.codexSnapshot == nil && !self.store.isStale(provider: .codex)
    }

    private var claudeShouldAnimate: Bool {
        self.store.isEnabled(.claude) && self.claudeSnapshot == nil && !self.store.isStale(provider: .claude)
    }
}

// MARK: - Status item controller (AppKit-hosted icons, SwiftUI popovers)

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let store: UsageStore
    private let settings: SettingsStore
    private let account: AccountInfo
    private let updater: UpdaterProviding
    private var statusItems: [UsageProvider: NSStatusItem] = [:]
    private var lastMenuProvider: UsageProvider?
    private var blinkTask: Task<Void, Never>?
    private var blinkAmount: CGFloat = 0
    private var cancellables = Set<AnyCancellable>()
    private let preferencesSelection: PreferencesSelection
    private var animationDisplayLink: CADisplayLink?
    private var animationPhase: Double = 0
    private var animationPattern: LoadingPattern = .knightRider

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
        for provider in UsageProvider.allCases {
            self.statusItems[provider] = bar.statusItem(withLength: NSStatusItem.variableLength)
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
    }

    private func wireBindings() {
        self.store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateIcons()
            }
            .store(in: &self.cancellables)

        self.store.$debugForceAnimation
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateVisibility()
            }
            .store(in: &self.cancellables)

        self.settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateVisibility()
            }
            .store(in: &self.cancellables)
    }

    private func installButtonsIfNeeded() {
        // No button actions needed when menus are attached directly.
    }

    private func updateIcons() {
        UsageProvider.allCases.forEach { self.applyIcon(for: $0, phase: nil) }
        self.attachMenus(fallback: self.fallbackProvider)
        self.updateAnimationState()
    }

    private func updateVisibility() {
        let fallback = self.fallbackProvider
        for provider in UsageProvider.allCases {
            let item = self.statusItems[provider]
            let isEnabled = self.isEnabled(provider)
            let force = self.store.debugForceAnimation
            item?.isVisible = isEnabled || fallback == provider || force
        }
        self.attachMenus(fallback: fallback)
        self.updateAnimationState()
    }

    private var fallbackProvider: UsageProvider? {
        self.store.enabledProviders().isEmpty ? .codex : nil
    }

    private func isEnabled(_ provider: UsageProvider) -> Bool {
        self.store.isEnabled(provider)
    }

    private func attachMenus(fallback: UsageProvider? = nil) {
        for provider in UsageProvider.allCases {
            guard let item = self.statusItems[provider] else { continue }
            if self.isEnabled(provider) {
                item.menu = self.makeMenu(for: provider)
            } else if fallback == provider {
                item.menu = self.makeMenu(for: nil)
            } else {
                item.menu = nil
            }
        }
    }

    private func startBlinkingIfNeeded() {
        let codexVisible = self.isEnabled(.codex) || self.fallbackProvider == .codex || self.store.debugForceAnimation
        if codexVisible {
            if self.blinkTask == nil {
                self.blinkTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(80))
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            if self.shouldAnimate(provider: .codex) { return } // skip during loading anim
                            self.blinkAmount = self.currentBlinkAmount()
                            self.applyIcon(for: .codex, phase: nil)
                        }
                    }
                }
            }
        } else {
            self.blinkTask?.cancel()
            self.blinkTask = nil
            self.blinkAmount = 0
        }
    }

    private func currentBlinkAmount(date: Date = .init()) -> CGFloat {
        let cycle: TimeInterval = 6.0
        let window: TimeInterval = 0.16
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        guard t < window else { return 0 }
        let mid = window / 2
        let dist = abs(t - mid)
        let normalized = max(0, 1 - dist / mid)
        return CGFloat(normalized)
    }

    private func applyIcon(for provider: UsageProvider, phase: Double?) {
        guard let button = self.statusItems[provider]?.button else { return }
        let snapshot = self.store.snapshot(for: provider)
        var primary = snapshot?.primary.remainingPercent
        var weekly = snapshot?.secondary.remainingPercent
        var credits: Double? = provider == .codex ? self.store.credits?.remaining : nil
        var stale = self.store.isStale(provider: provider)
        var morphProgress: Double?

        if let phase, self.shouldAnimate(provider: provider) {
            var pattern = self.animationPattern
            if provider == .claude, pattern == .unbraid {
                pattern = .cylon
            }
            if pattern == .unbraid {
                morphProgress = pattern.value(phase: phase) / 100
                primary = nil
                weekly = nil
                credits = nil
                stale = false
            } else {
                primary = pattern.value(phase: phase)
                weekly = pattern.value(phase: phase + pattern.secondaryOffset)
                credits = nil
                stale = false
            }
        }

        let style: IconStyle = self.store.style(for: provider)
        let blink = style == .codex ? self.blinkAmount : 0
        if let morphProgress {
            button.image = IconRenderer.makeMorphIcon(progress: morphProgress, style: style)
        } else {
            button.image = IconRenderer.makeIcon(
                primaryRemaining: primary,
                weeklyRemaining: weekly,
                creditsRemaining: credits,
                stale: stale,
                style: style,
                blink: blink)
        }
    }

    private func shouldAnimate(provider: UsageProvider) -> Bool {
        if self.store.debugForceAnimation { return true }

        let visible = self.store.debugForceAnimation || self.isEnabled(provider) || self.fallbackProvider == provider
        guard visible else { return false }

        let isStale = self.store.isStale(provider: provider)
        let hasData = self.store.snapshot(for: provider) != nil
        return !hasData && !isStale
    }

    private func updateAnimationState() {
        let needsAnimation = UsageProvider.allCases.contains { self.shouldAnimate(provider: $0) }
        if needsAnimation {
            if self.animationDisplayLink == nil {
                if let forced = self.settings.debugLoadingPattern {
                    self.animationPattern = forced
                } else if !LoadingPattern.allCases.contains(self.animationPattern) {
                    self.animationPattern = .knightRider
                }
                self.animationPhase = 0
                if let link = NSScreen.main?.displayLink(target: self, selector: #selector(self.animateIcons(_:))) {
                    link.add(to: .main, forMode: .common)
                    self.animationDisplayLink = link
                }
            } else if let forced = self.settings.debugLoadingPattern, forced != self.animationPattern {
                self.animationPattern = forced
                self.animationPhase = 0
            }
        } else {
            self.animationDisplayLink?.invalidate()
            self.animationDisplayLink = nil
            self.animationPhase = 0
            UsageProvider.allCases.forEach { self.applyIcon(for: $0, phase: nil) }
        }
    }

    @objc private func animateIcons(_ link: CADisplayLink) {
        self.animationPhase += 0.045 // half-speed animation
        UsageProvider.allCases.forEach { self.applyIcon(for: $0, phase: self.animationPhase) }
    }

    private func advanceAnimationPattern() {
        let patterns = LoadingPattern.allCases
        if let idx = patterns.firstIndex(of: self.animationPattern) {
            let next = patterns.indices.contains(idx + 1) ? patterns[idx + 1] : patterns.first
            self.animationPattern = next ?? .knightRider
        } else {
            self.animationPattern = .knightRider
        }
    }

    @objc private func handleDebugReplayNotification(_ notification: Notification) {
        if let raw = notification.userInfo?["pattern"] as? String,
           let selected = LoadingPattern(rawValue: raw)
        {
            self.animationPattern = selected
        } else if let forced = self.settings.debugLoadingPattern {
            self.animationPattern = forced
        } else {
            self.advanceAnimationPattern()
        }
        self.animationPhase = 0
        self.updateAnimationState()
    }

    deinit {
        self.blinkTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Actions reachable from menus

    @objc private func refreshNow() {
        Task { await self.store.refresh() }
    }

    @objc private func openDashboard() {
        let preferred = self.lastMenuProvider
            ?? (self.store.isEnabled(.codex) ? .codex : self.store.enabledProviders().first)

        let provider = preferred ?? .codex
        guard
            let urlString = self.store.metadata(for: provider).dashboardURL,
            let url = URL(string: urlString)
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func showSettingsGeneral() { self.openSettings(tab: .general) }

    @objc private func showSettingsAbout() { self.openSettings(tab: .about) }

    private func openSettings(tab: PreferencesTab) {
        DispatchQueue.main.async {
            self.preferencesSelection.tab = tab
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(
                name: .codexbarOpenSettings,
                object: nil,
                userInfo: ["tab": tab.rawValue])
        }
    }

    @objc private func openAbout() {
        showAbout()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func copyError(_ sender: NSMenuItem) {
        if let err = sender.representedObject as? String {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(err, forType: .string)
        }
    }
}

// MARK: - NSMenu construction

extension StatusItemController {
    private func makeMenu(for provider: UsageProvider?) -> NSMenu {
        self.lastMenuProvider = provider
        let descriptor = MenuDescriptor.build(
            provider: provider,
            store: self.store,
            settings: self.settings,
            account: self.account)
        let menu = NSMenu()
        menu.autoenablesItems = false

        for (index, section) in descriptor.sections.enumerated() {
            for entry in section.entries {
                switch entry {
                case let .text(text, style):
                    let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    if style == .headline {
                        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                        item.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
                    } else if style == .secondary {
                        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                        item.attributedTitle = NSAttributedString(
                            string: text,
                            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                    }
                    menu.addItem(item)
                case let .action(title, action):
                    let (selector, represented) = self.selector(for: action)
                    let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                    item.target = self
                    item.representedObject = represented
                    menu.addItem(item)
                case .divider:
                    menu.addItem(.separator())
                }
            }
            if index < descriptor.sections.count - 1 {
                menu.addItem(.separator())
            }
        }
        return menu
    }

    private func selector(for action: MenuDescriptor.MenuAction) -> (Selector, Any?) {
        switch action {
        case .refresh: (#selector(self.refreshNow), nil)
        case .dashboard: (#selector(self.openDashboard), nil)
        case .settings: (#selector(self.showSettingsGeneral), nil)
        case .about: (#selector(self.showSettingsAbout), nil)
        case .quit: (#selector(self.quit), nil)
        case let .copyError(message): (#selector(self.copyError(_:)), message)
        }
    }
}

extension Notification.Name {
    static let codexbarOpenSettings = Notification.Name("codexbarOpenSettings")
}

// MARK: - NSMenu helpers

extension NSMenu {
    @discardableResult
    fileprivate func addItem(title: String, isBold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if isBold {
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .bold)
            item.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
        }
        self.addItem(item)
        return item
    }
}
