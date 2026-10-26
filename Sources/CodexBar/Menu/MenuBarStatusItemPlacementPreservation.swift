import Foundation

/// Keeps `NSStatusItem Preferred Position <autosaveName>` across status-item mutations.
///
/// macOS 26 clears that default when a status item is removed or hidden while the app keeps running,
/// and a later item with the same autosave name then lands at the far left of the menu bar. CodexBar
/// removes and hides items for cleanup and recovery, not to forget where the user placed them, so the
/// saved valid position is written back when AppKit clears or corrupts it. Validation uses the same
/// display bounds as creation; unchanged valid positions are left alone, including during termination.
@MainActor
enum MenuBarStatusItemPlacementPreservation {
    @discardableResult
    static func preservingPreferredPosition<T>(
        autosaveName: String,
        defaults: UserDefaults,
        maximumPreferredPosition: Double? = MenuBarStatusItemPlacementPreflight.currentMaximumPreferredPosition(),
        _ body: () -> T) -> T
    {
        guard !autosaveName.isEmpty else { return body() }
        MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults, autosaveName: autosaveName, maximumPreferredPosition: maximumPreferredPosition)
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: autosaveName)
        let savedPosition = defaults.object(forKey: key)
        let result = body()
        MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults, autosaveName: autosaveName, maximumPreferredPosition: maximumPreferredPosition)
        if let savedPosition, defaults.object(forKey: key) == nil {
            defaults.set(savedPosition, forKey: key)
        }
        return result
    }
}
