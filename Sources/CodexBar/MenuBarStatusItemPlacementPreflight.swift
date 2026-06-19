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
        guard let number = value as? NSNumber else { return true }
        let position = number.doubleValue
        if position <= 0 {
            return true
        }
        guard let maximumPreferredPosition else { return false }
        return position > maximumPreferredPosition + self.suspiciousPreferredPositionPadding
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

    private static func currentMaximumPreferredPosition() -> Double? {
        NSScreen.screens.map { Double($0.frame.maxX) }.max()
    }
}
