import AppKit
import CodexBarCore

extension StatusItemController {
    /// Lazily retrieves or creates a status item for the given provider.
    func lazyStatusItem(for provider: UsageProvider) -> NSStatusItem {
        self.vendStatusItem(for: provider)
    }

    private func vendStatusItem(
        for provider: UsageProvider,
        onCreated: ((NSStatusItem) -> Void)? = nil)
        -> NSStatusItem
    {
        if let existing = self.statusItems[provider] {
            return existing
        }
        return Self.makeStatusItem(
            statusBar: self.statusBar,
            identity: .provider(provider),
            defaults: self.settings.userDefaults,
            legacyDefaultItemIndex: self.legacyDefaultItemIndex(forNewProvider: provider),
            onCreated: { item in
                // Register before invoking the caller/setup callbacks: button configuration and
                // icon-observation can synchronously re-enter vending for this provider, and an
                // unregistered item there vends a duplicate (issue #2162).
                self.statusItems[provider] = item
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
