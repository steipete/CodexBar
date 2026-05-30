import Foundation

enum MenuBarStatusItemPlacementPreflight {
    static let preferredPositionPrefix = "NSStatusItem Preferred Position "
    static let lowPreferredPosition: Double = 0
    static let suspiciousPreferredPositionThreshold: Double = 100

    static func preferredPositionKey(autosaveName: String) -> String {
        "\(self.preferredPositionPrefix)\(autosaveName)"
    }

    @discardableResult
    static func prepare(defaults: UserDefaults, autosaveName: String, legacyDefaultItemIndex: Int? = nil) -> Bool {
        let key = self.preferredPositionKey(autosaveName: autosaveName)
        let value = defaults.object(forKey: key)
        guard value != nil || !self.shouldPreserveMissingStableKey(
            defaults: defaults,
            legacyDefaultItemIndex: legacyDefaultItemIndex)
        else {
            return false
        }
        guard self.shouldSetPreferredPosition(value) else { return false }
        defaults.set(self.lowPreferredPosition, forKey: key)
        return true
    }

    static func shouldSetPreferredPosition(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let number = value as? NSNumber else { return true }
        return number.doubleValue > self.suspiciousPreferredPositionThreshold
    }

    static func shouldPreserveMissingStableKey(defaults: UserDefaults, legacyDefaultItemIndex: Int?) -> Bool {
        guard let legacyDefaultItemIndex else { return false }
        return self.legacyPreferredPositions(defaults: defaults).contains { position in
            position.itemIndex == legacyDefaultItemIndex && !self.shouldSetPreferredPosition(position.value)
        }
    }

    static func isLegacyPreferredPositionKey(_ key: String) -> Bool {
        guard key.hasPrefix(self.preferredPositionPrefix) else { return false }
        return self.isDefaultStatusItemName(String(key.dropFirst(self.preferredPositionPrefix.count)))
    }

    private static func legacyPreferredPositions(defaults: UserDefaults) -> [LegacyPreferredPosition] {
        defaults.dictionaryRepresentation().compactMap { key, value -> LegacyPreferredPosition? in
            guard key.hasPrefix(self.preferredPositionPrefix) else { return nil }
            let itemName = String(key.dropFirst(self.preferredPositionPrefix.count))
            guard let itemIndex = self.defaultStatusItemIndex(itemName) else { return nil }
            return LegacyPreferredPosition(itemIndex: itemIndex, value: value)
        }
    }

    private struct LegacyPreferredPosition {
        var itemIndex: Int
        var value: Any
    }

    private static func isDefaultStatusItemName(_ itemName: String) -> Bool {
        self.defaultStatusItemIndex(itemName) != nil
    }

    private static func defaultStatusItemIndex(_ itemName: String) -> Int? {
        guard itemName.hasPrefix("Item-") else { return nil }
        let suffix = itemName.dropFirst("Item-".count)
        guard suffix.allSatisfy(\.isNumber) else { return nil }
        return Int(suffix)
    }
}
