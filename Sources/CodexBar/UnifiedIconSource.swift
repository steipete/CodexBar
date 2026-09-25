import Foundation

enum UnifiedIconSource: String, CaseIterable, Sendable {
    case currentSelection
    case highestUsage
    case frontmostApp

    var label: String {
        switch self {
        case .currentSelection: L("merged_icon_source_current_selection")
        case .highestUsage: L("merged_icon_source_highest_usage")
        case .frontmostApp: L("merged_icon_source_frontmost_app")
        }
    }
}
