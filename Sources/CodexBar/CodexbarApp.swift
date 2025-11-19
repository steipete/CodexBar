import SwiftUI
import Security
import AppKit
import Combine
import QuartzCore

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
        self.appDelegate.configure(store: _store.wrappedValue, settings: settings, account: self.account, selection: self.preferencesSelection)
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
    controller.start()
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

    func configure(store: UsageStore, settings: SettingsStore, account: AccountInfo, selection: PreferencesSelection) {
        self.statusController = StatusItemController(
            store: store,
            settings: settings,
            account: account,
            updater: self.updaterController,
            preferencesSelection: selection)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If not configured yet (shouldn't happen), create a minimal controller.
        if self.statusController == nil {
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
        self.settings.showCodexUsage && self.codexSnapshot == nil && !self.store.isStale(provider: .codex)
    }
    private var claudeShouldAnimate: Bool {
        self.settings.showClaudeUsage && self.claudeSnapshot == nil && !self.store.isStale(provider: .claude)
    }
}

// MARK: - Status item controller (AppKit-hosted icons, SwiftUI popovers)

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let store: UsageStore
    private let settings: SettingsStore
    private let account: AccountInfo
    private let updater: UpdaterProviding
    private let codexItem: NSStatusItem
    private let claudeItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()
    private let preferencesSelection: PreferencesSelection
    private var animationDisplayLink: CADisplayLink?
    private var animationPhase: Double = 0
    private var animationPattern: LoadingPattern = .knightRider

    init(store: UsageStore, settings: SettingsStore, account: AccountInfo, updater: UpdaterProviding, preferencesSelection: PreferencesSelection) {
        self.store = store
        self.settings = settings
        self.account = account
        self.updater = updater
        self.preferencesSelection = preferencesSelection
        let bar = NSStatusBar.system
        self.codexItem = bar.statusItem(withLength: NSStatusItem.variableLength)
        self.claudeItem = bar.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        self.wireBindings()
        self.updateIcons()
        self.updateVisibility()
        NotificationCenter.default.addObserver(self, selector: #selector(self.handleDebugReplayNotification), name: .codexbarDebugReplayAllAnimations, object: nil)
    }

    private func wireBindings() {
        self.store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateIcons()
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
        self.applyIcon(for: .codex, phase: nil)
        self.applyIcon(for: .claude, phase: nil)
        self.attachMenus(fallback: self.fallbackProvider)
        self.updateAnimationState()
    }

    private func updateVisibility() {
        let fallback = self.fallbackProvider
        self.codexItem.isVisible = self.settings.showCodexUsage || fallback == .codex
        self.claudeItem.isVisible = self.settings.showClaudeUsage
        self.attachMenus(fallback: fallback)
        self.updateAnimationState()
    }

    private var fallbackProvider: UsageProvider? {
        (!self.settings.showCodexUsage && !self.settings.showClaudeUsage) ? .codex : nil
    }

    private func attachMenus(fallback: UsageProvider? = nil) {
        if self.settings.showCodexUsage {
            self.codexItem.menu = self.makeMenu(for: .codex)
        } else if fallback == .codex {
            self.codexItem.menu = self.makeMenu(for: nil)
        } else {
            self.codexItem.menu = nil
        }
        self.claudeItem.menu = self.settings.showClaudeUsage ? self.makeMenu(for: .claude) : nil
    }

    private func applyIcon(for provider: UsageProvider, phase: Double?) {
        let button = provider == .codex ? self.codexItem.button : self.claudeItem.button
        guard let button else { return }
        let snapshot = self.store.snapshot(for: provider)
        var primary = snapshot?.primary.remainingPercent
        var weekly = snapshot?.secondary.remainingPercent
        var credits: Double? = provider == .codex ? self.store.credits?.remaining : nil
        var stale = self.store.isStale(provider: provider)

        if let phase, self.shouldAnimate(provider: provider) {
            let pattern = self.animationPattern
            primary = pattern.value(phase: phase)
            weekly = pattern.value(phase: phase + pattern.secondaryOffset)
            credits = nil
            stale = false
        }

        button.image = IconRenderer.makeIcon(
            primaryRemaining: primary,
            weeklyRemaining: weekly,
            creditsRemaining: credits,
            stale: stale,
            style: provider == .codex ? .codex : .claude)
    }

    private func shouldAnimate(provider: UsageProvider) -> Bool {
        switch provider {
        case .codex:
            guard self.settings.showCodexUsage else { return false }
        case .claude:
            guard self.settings.showClaudeUsage else { return false }
        }
        return self.store.snapshot(for: provider) == nil && !self.store.isStale(provider: provider)
    }

    private func updateAnimationState() {
        let needsAnimation = self.shouldAnimate(provider: .codex) || self.shouldAnimate(provider: .claude)
        if needsAnimation {
            if self.animationDisplayLink == nil {
                self.animationPattern = LoadingPattern.allCases.randomElement() ?? .knightRider
                self.animationPhase = 0
                if let link = NSScreen.main?.displayLink(target: self, selector: #selector(self.animateIcons(_:))) {
                    link.add(to: .main, forMode: .common)
                    self.animationDisplayLink = link
                }
            }
        } else {
            self.animationDisplayLink?.invalidate()
            self.animationDisplayLink = nil
            self.animationPhase = 0
            self.applyIcon(for: .codex, phase: nil)
            self.applyIcon(for: .claude, phase: nil)
        }
    }

    @objc private func animateIcons(_ link: CADisplayLink) {
        self.animationPhase += 0.09
        self.applyIcon(for: .codex, phase: self.animationPhase)
        self.applyIcon(for: .claude, phase: self.animationPhase)
    }

    @objc private func handleDebugReplayNotification() {
        let patterns = LoadingPattern.allCases
        if let idx = patterns.firstIndex(of: self.animationPattern) {
            let next = patterns.indices.contains(idx + 1) ? patterns[idx + 1] : patterns.first
            self.animationPattern = next ?? .knightRider
        } else {
            self.animationPattern = .knightRider
        }
        self.animationPhase = 0
        self.updateAnimationState()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Actions reachable from menus

    @objc private func refreshNow() {
        Task { await self.store.refresh() }
    }

    @objc private func openDashboard() {
        if let url = URL(string: "https://chatgpt.com/codex/settings/usage") {
            NSWorkspace.shared.open(url)
        }
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

private extension StatusItemController {
    func makeMenu(for provider: UsageProvider?) -> NSMenu {
        let descriptor = MenuDescriptor.build(provider: provider, store: self.store, settings: self.settings, account: self.account)
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
                        item.attributedTitle = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
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
        case .refresh: return (#selector(refreshNow), nil)
        case .dashboard: return (#selector(openDashboard), nil)
        case .settings: return (#selector(showSettingsGeneral), nil)
        case .about: return (#selector(showSettingsAbout), nil)
        case .quit: return (#selector(quit), nil)
        case let .copyError(message): return (#selector(copyError(_:)), message)
        }
    }

}

extension Notification.Name {
    static let codexbarOpenSettings = Notification.Name("codexbarOpenSettings")
}

// MARK: - NSMenu helpers

private extension NSMenu {
    @discardableResult
    func addItem(title: String, isBold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if isBold {
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .bold)
            item.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
        }
        self.addItem(item)
        return item
    }
}
