import AppKit
import CodexBarCore

extension StatusItemController {
    /// Lazily retrieves or creates a status item for the given provider.
    func lazyStatusItem(for provider: UsageProvider) -> NSStatusItem {
        self.vendStatusItem(for: provider)
    }

    /// Removes a status item while keeping its saved menu bar position (see
    /// `MenuBarStatusItemPlacementPreservation`).
    func removeStatusItemPreservingPlacement(_ item: NSStatusItem) {
        MenuBarStatusItemPlacementPreservation.removeStatusItem(
            item,
            from: self.statusBar,
            defaults: self.settings.userDefaults)
    }

    /// Shows or hides a status item while keeping its saved menu bar position.
    func setStatusItemVisiblePreservingPlacement(_ item: NSStatusItem, _ isVisible: Bool) {
        MenuBarStatusItemPlacementPreservation.setVisible(isVisible, for: item, defaults: self.settings.userDefaults)
    }

    private func vendStatusItem(
        for provider: UsageProvider,
        onCreated: ((NSStatusItem) -> Void)? = nil)
        -> NSStatusItem
    {
        if let existing = self.statusItems[provider.instanceID] {
            return existing
        }
        return Self.makeStatusItem(
            statusBar: self.statusBar,
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
        self.vendStatusItem(for: provider, onCreated: onCreated)
    }
    #endif
}
