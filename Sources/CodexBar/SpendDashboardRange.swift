import Foundation

enum SpendDashboardRange: Int, CaseIterable, Sendable, Equatable {
    case last7Days = 7
    case last30Days = 30
    case allTime = 0

    var dayCount: Int? {
        switch self {
        case .last7Days: 7
        case .last30Days: 30
        case .allTime: nil
        }
    }

    static func storedValue(_ value: Int) -> Self {
        Self(rawValue: value) ?? .last30Days
    }
}
