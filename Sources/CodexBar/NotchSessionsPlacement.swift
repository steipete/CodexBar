import Foundation

/// Which side of the provider grid the agent-session band sits on. The band is always full width
/// with its own height budget, so there is no in-grid option.
enum NotchSessionsPlacement: String, CaseIterable, Sendable {
    case above
    case below

    var label: String {
        switch self {
        case .above: L("notch_sessions_placement_above")
        case .below: L("notch_sessions_placement_below")
        }
    }
}
