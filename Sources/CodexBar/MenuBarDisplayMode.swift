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
        case .percent: L("display_mode_percent")
        case .pace: L("display_mode_pace")
        case .both: L("display_mode_both")
        }
    }

    var description: String {
        switch self {
        case .percent: L("display_mode_percent_desc")
        case .pace: L("display_mode_pace_desc")
        case .both: L("display_mode_both_desc")
        }
    }
}

/// Controls which time window drives the percent and pace values in the menu bar.
enum MenuBarTimeWindow: String, CaseIterable, Identifiable {
    case session
    case weekly

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .session: "Session"
        case .weekly: "Weekly"
        }
    }
}
