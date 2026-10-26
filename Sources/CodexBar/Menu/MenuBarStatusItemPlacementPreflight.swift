import AppKit
import CodexBarCore

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
        let names = [autosaveName] + (legacyDefaultItemIndex.map { ["Item-\($0)"] } ?? [])
        let keys = names.map { self.preferredPositionKey(autosaveName: $0) }.filter { key in
            defaults.object(forKey: key).map {
                self.shouldClearPreferredPosition($0, maximumPreferredPosition: maximumPreferredPosition)
            } ?? false
        }
        for key in keys {
            defaults.removeObject(forKey: key)
            CodexBarLog.logger(LogCategories.app).info(
                "Repaired macOS status-item preferred position", metadata: ["key": key])
        }
        return !keys.isEmpty
    }

    static func shouldClearPreferredPosition(_ value: Any, maximumPreferredPosition: Double?) -> Bool {
        guard let position = (value as? NSNumber)?.doubleValue,
              position.isFinite, position > 0 else { return true }
        return maximumPreferredPosition.map { position > $0 + self.suspiciousPreferredPositionPadding } ?? false
    }

    static func currentMaximumPreferredPosition(screenFrames: [CGRect] = NSScreen.screens.map(\.frame)) -> Double? {
        screenFrames.map { Double($0.width) }.max()
    }
}
