import AppKit
import CodexBarCore
import Observation

/// Keeps a usage overview visible on the physical Touch Bar at all times, not just while a
/// CodexBar window is key. Uses the same undocumented system-modal presentation path as
/// MTMR/Pock — see `SystemModalTouchBarRuntime`.
///
/// Content is plain AppKit (`TouchBarProviderCardView`/`TouchBarProviderGraphView`), not
/// SwiftUI — see `TouchBarAppKitViews.swift` for why: `NSHostingView` doesn't receive touch
/// input under `presentSystemModalTouchBar:`.
@MainActor
final class PersistentUsageTouchBarController: NSObject, NSTouchBarDelegate {
    private static let barIdentifier = NSTouchBar.CustomizationIdentifier("com.steipete.codexbar.persistentBar")
    private static let itemIdentifier = NSTouchBarItem.Identifier("com.steipete.codexbar.persistentItem")
    private static let maxCards = 3
    /// Tapping a card leaves the graph up long enough to read, then reverts to the overview
    /// on its own — the Touch Bar has no natural "back" affordance besides tapping again.
    private static let autoRevertSeconds: TimeInterval = 8
    /// Only take over the physical Touch Bar while an IDE/dev-multiplexer-like app (Kouen,
    /// Xcode, VS Code, ...) is frontmost — otherwise it steals the Touch Bar from whatever app
    /// the user is actually in. Checked by `LSApplicationCategoryType` rather than a hardcoded
    /// bundle ID list: every app in that bucket declares `public.app-category.developer-tools`
    /// in its Info.plist, so new IDEs need no code change here. Plain terminal emulators
    /// (Terminal.app, iTerm2, Warp) are deliberately excluded — they're categorized as
    /// "Utilities", not "Developer Tools", which matches the intent: IDE/multiplexer-like apps,
    /// not bare shells.
    private static let developerToolsCategory = "public.app-category.developer-tools"
    /// Patches for apps that ARE IDE/dev-tool-like but don't declare `LSApplicationCategoryType`
    /// at all, or where the category alone would still miss them. Antigravity
    /// (`com.google.antigravity`) and Codex (`com.openai.codex`) are deliberately NOT here —
    /// both already declare the developer-tools category on this machine and need no patch.
    ///
    /// Confidence varies by entry — `dev.zed.Zed` was verified directly on this machine
    /// (installed, confirmed no category key). The rest were sourced from public
    /// documentation/community reports, not verified against a local install — if one doesn't
    /// actually match, it's a harmless no-op string; fix by correcting/adding to this set.
    private static let developerToolsBundleIdentifierFallback: Set<String> = [
        "dev.zed.Zed", // Zed — verified locally: no LSApplicationCategoryType key at all
        "com.exafunction.windsurf", // Windsurf, and Devin Desktop (same bundle ID post-rebrand)
        "com.openai.chat", // ChatGPT desktop (source: public docs, not verified locally)
        "com.sublimetext.4", // Sublime Text 4
        "com.neovide.neovide", // Neovide (Neovim GUI)
        "com.qvacua.VimR", // VimR (Neovim GUI)
        "com.panic.Nova", // Nova
        "com.barebones.bbedit", // BBEdit
    ]

    private let settings: SettingsStore
    private let store: UsageStore
    private var touchBar: NSTouchBar?
    private var container: NSStackView?
    private var expandedProvider: UsageProvider?
    private var expandedWindow: TouchBarWindowKind = .primary
    private var revertWorkItem: DispatchWorkItem?
    private var frontmostAppObserver: NSObjectProtocol?
    private var isShowingOnPhysicalTouchBar = false

    init(settings: SettingsStore, store: UsageStore) {
        self.settings = settings
        self.store = store
    }

    func present() {
        self.frontmostAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main)
        { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePresentationForFrontmostApp()
            }
        }
        self.updatePresentationForFrontmostApp()
    }

    private func updatePresentationForFrontmostApp() {
        let isDevTool = Self.isDeveloperToolsApp(NSWorkspace.shared.frontmostApplication)
        if isDevTool, !self.isShowingOnPhysicalTouchBar {
            self.showOnPhysicalTouchBar()
        } else if !isDevTool, self.isShowingOnPhysicalTouchBar {
            self.hideFromPhysicalTouchBar()
        }
    }

    static func isDeveloperToolsApp(_ app: NSRunningApplication?) -> Bool {
        self.isDeveloperToolsApp(bundleURL: app?.bundleURL)
    }

    static func isDeveloperToolsApp(bundleURL: URL?) -> Bool {
        guard let bundleURL, let bundle = Bundle(url: bundleURL) else { return false }
        if let category = bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String,
           category == Self.developerToolsCategory
        {
            return true
        }
        guard let bundleIdentifier = bundle.bundleIdentifier else { return false }
        return Self.developerToolsBundleIdentifierFallback.contains(bundleIdentifier)
    }

    private func showOnPhysicalTouchBar() {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.customizationIdentifier = Self.barIdentifier
        bar.defaultItemIdentifiers = [Self.itemIdentifier]
        self.touchBar = bar
        self.isShowingOnPhysicalTouchBar = true

        SystemModalTouchBarRuntime.setCloseBoxVisibleWhenFrontmost(false)
        SystemModalTouchBarRuntime.presentSystemModal(
            bar,
            placement: 1,
            systemTrayItemIdentifier: Self.itemIdentifier)
    }

    func dismiss() {
        if let frontmostAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(frontmostAppObserver)
            self.frontmostAppObserver = nil
        }
        self.hideFromPhysicalTouchBar()
    }

    private func hideFromPhysicalTouchBar() {
        self.revertWorkItem?.cancel()
        self.isShowingOnPhysicalTouchBar = false
        guard let touchBar else { return }
        SystemModalTouchBarRuntime.dismissSystemModal(touchBar)
        self.touchBar = nil
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.itemIdentifier else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.frame = NSRect(x: 0, y: 0, width: 400, height: 30)
        item.view = stack
        self.container = stack
        self.rebuildContent()
        // Registered here, not in present() — withObservationTracking only tracks
        // properties actually read inside its closure, and rebuildContent() no-ops
        // (reads nothing observable) before `container` exists. Presenting the bar
        // doesn't synchronously call this delegate method, so tracking from present()
        // could register zero dependencies and never fire again.
        self.observeStoreChanges()
        return item
    }

    // MARK: - Live updates

    private func observeStoreChanges() {
        withObservationTracking {
            self.rebuildContent()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeStoreChanges()
            }
        }
    }

    // MARK: - Content

    private var cardProviders: [UsageProvider] {
        Array(self.store.enabledProviders().prefix(Self.maxCards))
    }

    private func rebuildContent() {
        guard let container else { return }
        container.arrangedSubviews.forEach {
            container.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if let expandedProvider, self.cardProviders.contains(expandedProvider) {
            container.addArrangedSubview(self.makeGraphView(for: expandedProvider))
            self.scheduleAutoRevert()
        } else {
            let providers = self.cardProviders
            for (index, provider) in providers.enumerated() {
                if index > 0 {
                    let divider = NSBox()
                    divider.boxType = .separator
                    divider.translatesAutoresizingMaskIntoConstraints = false
                    divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
                    container.addArrangedSubview(divider)
                }
                container.addArrangedSubview(self.makeCardView(for: provider))
            }
            if providers.isEmpty {
                let label = NSTextField(labelWithString: "No providers enabled")
                label.font = .systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
                container.addArrangedSubview(label)
            }
        }
    }

    private func makeCardView(for provider: UsageProvider) -> TouchBarProviderCardView {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let card = TouchBarProviderCardView(provider: provider)
        card.apply(descriptor: descriptor, snapshot: self.store.snapshot(for: provider))
        card.onTap = { [weak self] in self?.expand(provider) }
        return card
    }

    private func makeGraphView(for provider: UsageProvider) -> TouchBarProviderGraphView {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let view = TouchBarProviderGraphView(provider: provider)
        view.apply(descriptor: descriptor, snapshot: self.store.snapshot(for: provider), window: self.expandedWindow)
        view.onTap = { [weak self] in self?.advance() }
        return view
    }

    private func expand(_ provider: UsageProvider) {
        self.expandedProvider = provider
        self.expandedWindow = .primary
        self.rebuildContent()
    }

    /// Tapping the expanded graph cycles 5h -> weekly -> back to the overview cards,
    /// rather than collapsing immediately — both windows are worth a look per tap-in.
    private func advance() {
        switch self.expandedWindow {
        case .primary:
            self.expandedWindow = .secondary
            self.rebuildContent()
        case .secondary:
            self.collapse()
        }
    }

    private func collapse() {
        self.expandedProvider = nil
        self.expandedWindow = .primary
        self.revertWorkItem?.cancel()
        self.rebuildContent()
    }

    private func scheduleAutoRevert() {
        self.revertWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.collapse()
        }
        self.revertWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoRevertSeconds, execute: workItem)
    }
}
