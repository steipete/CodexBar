import Foundation

enum MenuBarStatusItemPlacementPreflight {
    static let preferredPositionPrefix = "NSStatusItem Preferred Position "
    static let lowPreferredPosition: Double = 0
    static let suspiciousPreferredPositionThreshold: Double = 100

    static func preferredPositionKey(autosaveName: String) -> String {
        "\(self.preferredPositionPrefix)\(autosaveName)"
    }

    @discardableResult
    static func prepare(defaults: UserDefaults, autosaveName: String) -> Bool {
        let key = self.preferredPositionKey(autosaveName: autosaveName)
        guard self.shouldSetPreferredPosition(defaults.object(forKey: key)) else { return false }
        defaults.set(self.lowPreferredPosition, forKey: key)
        return true
    }

    static func shouldSetPreferredPosition(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let number = value as? NSNumber else { return true }
        return number.doubleValue > self.suspiciousPreferredPositionThreshold
    }
}
