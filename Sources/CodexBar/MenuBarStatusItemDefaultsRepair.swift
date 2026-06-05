import Foundation

enum MenuBarStatusItemDefaultsRepair {
    static let didRepairKey = "hasRepairedHiddenStatusItemVisibilityDefaults"
    private static let visibilityPrefix = "NSStatusItem VisibleCC "
    private static let legacyAutosavePrefix = "codexbar-"

    static func repairHiddenVisibilityDefaultsIfNeeded(defaults: UserDefaults) -> [String] {
        let repairedKeys = defaults.dictionaryRepresentation().keys
            .filter { key in
                self.shouldRepair(key: key, value: defaults.object(forKey: key))
            }
            .sorted()

        for key in repairedKeys {
            defaults.removeObject(forKey: key)
        }
        if !defaults.bool(forKey: self.didRepairKey) {
            defaults.set(true, forKey: self.didRepairKey)
        }
        return repairedKeys
    }

    static func shouldRepair(key: String, value: Any?) -> Bool {
        guard key.hasPrefix(self.visibilityPrefix), self.isFalse(value) else { return false }
        let itemName = String(key.dropFirst(self.visibilityPrefix.count))
        return itemName.hasPrefix(self.legacyAutosavePrefix) || self.isDefaultStatusItemName(itemName)
    }

    private static func isDefaultStatusItemName(_ itemName: String) -> Bool {
        guard itemName.hasPrefix("Item-") else { return false }
        return itemName.dropFirst("Item-".count).allSatisfy(\.isNumber)
    }

    private static func isFalse(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber:
            !number.boolValue
        case let bool as Bool:
            !bool
        default:
            false
        }
    }
}
