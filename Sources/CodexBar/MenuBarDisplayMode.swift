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
        case .percent: "Percent"
        case .pace: "Pace"
        case .both: "Both"
        }
    }

    var description: String {
        switch self {
        case .percent: "Show remaining/used percentage (e.g. 45%)"
        case .pace: "Show pace indicator (e.g. +5%)"
        case .both: "Show both percentage and pace (e.g. 45% · +5%)"
        }
    }
}
