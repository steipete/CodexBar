import AppKit

/// Keeps `NSStatusItem Preferred Position <autosaveName>` across status-item mutations.
///
/// macOS 26 clears that default when a status item is removed or hidden while the app keeps running,
/// and a later item with the same autosave name then lands at the far left of the menu bar. CodexBar
/// removes and hides items for cleanup and recovery, not to forget where the user placed them, so the
/// saved position is written back when AppKit cleared it. Termination-time removals leave the default
/// untouched and are a no-op here.
@MainActor
enum MenuBarStatusItemPlacementPreservation {
    @discardableResult
    static func preservingPreferredPosition<T>(
        autosaveName: String,
        defaults: UserDefaults,
        _ body: () -> T) -> T
    {
        guard !autosaveName.isEmpty else { return body() }
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: autosaveName)
        let savedPosition = defaults.object(forKey: key)
        let result = body()
        if let savedPosition, defaults.object(forKey: key) == nil {
            defaults.set(savedPosition, forKey: key)
        }
        return result
    }

    static func removeStatusItem(_ item: NSStatusItem, from statusBar: NSStatusBar, defaults: UserDefaults) {
        self.preservingPreferredPosition(autosaveName: item.autosaveName ?? "", defaults: defaults) {
            // Retire the autosave identity before AppKit's later cleanup can clear the stable key again.
            item.autosaveName = nil
            statusBar.removeStatusItem(item)
        }
    }

    static func setVisible(_ isVisible: Bool, for item: NSStatusItem, defaults: UserDefaults) {
        self.preservingPreferredPosition(autosaveName: item.autosaveName ?? "", defaults: defaults) {
            item.isVisible = isVisible
        }
    }
}
