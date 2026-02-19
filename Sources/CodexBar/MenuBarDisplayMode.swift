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
        switch self {
        case .percent: L10n.tr("Percent")
        case .pace: L10n.tr("Pace")
        case .both: L10n.tr("Both")
        }
    }

    var description: String {
        switch self {
        case .percent: L10n.tr("Show remaining/used percentage (e.g. 45%)")
        case .pace: L10n.tr("Show pace indicator (e.g. +5%)")
        case .both: L10n.tr("Show both percentage and pace (e.g. 45% · +5%)")
        }
    }
}
