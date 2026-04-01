import Foundation

/// Sorting is part of the multi-account Codex workflow: once several accounts are visible
/// together, it becomes useful to order them by reset time or remaining quota, not just by name.
enum CodexMenuAccountSortMode: String, CaseIterable, Sendable {
    case accountNameAscending = "account-name-ascending"
    case accountNameDescending = "account-name-descending"
    case sessionLeftHighToLow = "session-left-high-to-low"
    case sessionResetSoonestFirst = "session-reset-soonest-first"
    case weeklyLeftHighToLow = "weekly-left-high-to-low"
    case weeklyResetSoonestFirst = "weekly-reset-soonest-first"

    static let `default`: Self = .accountNameAscending

    var menuTitle: String {
        switch self {
        case .accountNameAscending: "Name A–Z"
        case .accountNameDescending: "Name Z–A"
        case .sessionLeftHighToLow: "Session left ↓"
        case .sessionResetSoonestFirst: "Session reset soonest"
        case .weeklyLeftHighToLow: "Weekly left ↓"
        case .weeklyResetSoonestFirst: "Weekly reset soonest"
        }
    }

    var compactTitle: String {
        switch self {
        case .accountNameAscending: "Name A–Z"
        case .accountNameDescending: "Name Z–A"
        case .sessionLeftHighToLow: "Session ↓"
        case .sessionResetSoonestFirst: "Session reset soonest"
        case .weeklyLeftHighToLow: "Weekly ↓"
        case .weeklyResetSoonestFirst: "Weekly reset soonest"
        }
    }
}
