import Foundation

/// Controls what the menu bar displays when brand icon mode is enabled.
enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case percent
    case pace
    case both

    var id: String {
        self.rawValue
    }

    var label: String {
        AppStrings.menuBarDisplayMode(self)
    }

    var description: String {
        AppStrings.menuBarDisplayModeDescription(self)
    }
}
