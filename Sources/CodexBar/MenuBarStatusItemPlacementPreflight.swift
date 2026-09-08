import AppKit

@MainActor
enum MenuBarStatusItemPlacementPreflight {
    static let preferredPositionPrefix = "NSStatusItem Preferred Position "
    static let suspiciousPreferredPositionPadding: Double = 512

    static func preferredPositionKey(autosaveName: String) -> String {
        "\(self.preferredPositionPrefix)\(autosaveName)"
    }

    @discardableResult
    static func prepare(
        defaults: UserDefaults,
        autosaveName: String,
        legacyDefaultItemIndex: Int? = nil,
        maximumPreferredPosition: Double? = currentMaximumPreferredPosition())
        -> Bool
    {
        let key = self.preferredPositionKey(autosaveName: autosaveName)
        var repaired = self.clearPreferredPositionIfNeeded(
            defaults: defaults,
            key: key,
            maximumPreferredPosition: maximumPreferredPosition)
        if let legacyDefaultItemIndex {
            let legacyKey = self.preferredPositionKey(autosaveName: "Item-\(legacyDefaultItemIndex)")
            repaired = self.clearPreferredPositionIfNeeded(
                defaults: defaults,
                key: legacyKey,
                maximumPreferredPosition: maximumPreferredPosition) || repaired
        }
        return repaired
    }

    static func shouldClearPreferredPosition(_ value: Any, maximumPreferredPosition: Double?) -> Bool {
        guard let position = (value as? NSNumber)?.doubleValue,
              position.isFinite, position > 0 else { return true }
        return maximumPreferredPosition.map { position > $0 + self.suspiciousPreferredPositionPadding } ?? false
    }

    private static func clearPreferredPositionIfNeeded(
        defaults: UserDefaults,
        key: String,
        maximumPreferredPosition: Double?)
        -> Bool
    {
        guard let value = defaults.object(forKey: key),
              self.shouldClearPreferredPosition(value, maximumPreferredPosition: maximumPreferredPosition)
        else { return false }
        defaults.removeObject(forKey: key)
        return true
    }

    static func currentMaximumPreferredPosition(screenFrames: [CGRect] = NSScreen.screens.map(\.frame)) -> Double? {
        // Preserve the legacy parking range while covering wide displays left of the primary screen.
        screenFrames.map { Double(max($0.width, $0.maxX)) }.max()
    }
}
