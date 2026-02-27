import Foundation

/// Controls Codex icon rendering in the menu bar when brand+text mode is disabled.
enum CodexMenuBarVisualizationMode: String, CaseIterable, Identifiable {
    case classic
    case pieRing
    case pieRingSwapped

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .classic: "Classic bars"
        case .pieRing: "Pie + ring"
        case .pieRingSwapped: "Pie + ring (swapped)"
        }
    }

    var description: String {
        switch self {
        case .classic: "Default Codex bar icon."
        case .pieRing: "Inner weekly pie + outer 5-hour ring."
        case .pieRingSwapped: "Inner 5-hour pie + outer weekly ring."
        }
    }

    var usesPieRingLayout: Bool {
        self != .classic
    }

    var placesWeeklyInOuterRing: Bool {
        self == .pieRingSwapped
    }
}
