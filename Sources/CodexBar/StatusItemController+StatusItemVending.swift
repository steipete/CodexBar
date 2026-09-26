import AppKit
import CodexBarCore

@MainActor
protocol StatusItemConfiguring: AnyObject {
    var autosaveName: String! { get set }
    var length: CGFloat { get set }
    var button: NSStatusBarButton? { get }
}

extension NSStatusItem: StatusItemConfiguring {}

extension StatusItemController {
    static func makeStatusItem<Item: StatusItemConfiguring>(
        create: (CGFloat) -> Item,
        identity: StatusItemIdentity,
        defaults: UserDefaults,
        legacyDefaultItemIndex: Int?,
        onCreated: ((Item) -> Void)? = nil)
        -> Item
    {
        MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults,
            autosaveName: identity.autosaveName,
            legacyDefaultItemIndex: legacyDefaultItemIndex)
        // AppKit has no named factory: keep the item zero-width until its stable identity is attached.
        let item = create(0)
        MenuBarStatusItemWindowProbe.trace("created", item: item as? NSStatusItem)
        // Registration must see the stable identity before its callback can re-enter setup.
        item.autosaveName = identity.autosaveName
        MenuBarStatusItemWindowProbe.trace("named", item: item as? NSStatusItem)
        onCreated?(item)
        // Reentrant registration may have already rendered a custom width.
        if item.length == 0 {
            item.length = NSStatusItem.variableLength
        }
        MenuBarStatusItemWindowProbe.trace("sized", item: item as? NSStatusItem)
        if let button = item.button {
            let title = self.statusItemAccessibilityTitle(
                isDebugApp: self.isDebugApp(bundleIdentifier: Bundle.main.bundleIdentifier))
            // Ensure the icon is rendered at 1:1 without resampling (crisper edges for template images).
            button.imageScaling = .scaleNone
            button.setAccessibilityIdentifier(identity.accessibilityIdentifier)
            button.setAccessibilityTitle(title)
        }
        return item
    }

    /// Removes a status item while keeping its saved menu bar position (see
    /// `MenuBarStatusItemPlacementPreservation`).
    func removeStatusItemPreservingPlacement(_ item: NSStatusItem) {
        MenuBarStatusItemPlacementPreservation.preservingPreferredPosition(
            autosaveName: item.autosaveName ?? "", defaults: self.settings.userDefaults)
        {
            if !self.hasPreparedForAppShutdown {
                // Retire runtime identities before later cleanup can clear the restored position.
                item.autosaveName = nil
            }
            // Renaming immediately before exit can leave Control Center hosting a blank Item-0 slot.
            self.statusBar.removeStatusItem(item)
        }
    }

    /// Shows or hides a status item while keeping its saved menu bar position.
    func setStatusItemVisiblePreservingPlacement(_ item: NSStatusItem, _ isVisible: Bool) {
        MenuBarStatusItemPlacementPreservation.preservingPreferredPosition(
            autosaveName: item.autosaveName ?? "", defaults: self.settings.userDefaults)
        {
            item.isVisible = isVisible
        }
    }

    /// Lazily retrieves or creates a status item for the given provider.
    func lazyStatusItem(
        for provider: UsageProvider,
        onCreated: ((NSStatusItem) -> Void)? = nil)
        -> NSStatusItem
    {
        if let existing = self.statusItems[provider.instanceID] {
            return existing
        }
        return Self.makeStatusItem(
            create: self.statusBar.statusItem(withLength:),
            identity: .provider(provider.instanceID),
            defaults: self.settings.userDefaults,
            legacyDefaultItemIndex: self.legacyDefaultItemIndex(forNewProvider: provider),
            onCreated: { item in
                // Register before invoking the caller/setup callbacks: button configuration and
                // icon-observation can synchronously re-enter vending for this provider, and an
                // unregistered item there vends a duplicate (issue #2162).
                self.statusItems[provider.instanceID] = item
                onCreated?(item)
            })
    }

    #if DEBUG
    func _test_vendStatusItem(
        for provider: UsageProvider,
        onCreated: @escaping (NSStatusItem) -> Void)
        -> NSStatusItem
    {
        self.lazyStatusItem(for: provider, onCreated: onCreated)
    }
    #endif
}
