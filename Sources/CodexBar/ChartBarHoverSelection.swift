import Foundation

enum ChartBarHoverSelection {
    static func accepts(distanceFromBarCenter: CGFloat, barHalfWidth: CGFloat, selectableCount: Int) -> Bool {
        selectableCount <= 1 || distanceFromBarCenter <= barHalfWidth
    }

    static func nextCalendarDay(after date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86400)
    }
}
