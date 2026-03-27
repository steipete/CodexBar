import Foundation

public enum ClaudePeakHours: Sendable {
    private static let peakTimeZone = TimeZone(identifier: "America/New_York")!
    private static let peakStartHour = 8
    private static let peakEndHour = 14

    public struct Status: Sendable, Equatable {
        public let isPeak: Bool
        public let label: String
    }

    public static func status(at date: Date) -> Status {
        let calendar = self.calendar()
        let components = calendar.dateComponents([.hour, .minute, .weekday], from: date)

        guard let hour = components.hour,
              let minute = components.minute,
              let weekday = components.weekday
        else {
            return Status(isPeak: false, label: "Off-peak")
        }

        let isWeekday = weekday >= 2 && weekday <= 6
        let nowMinutes = hour * 60 + minute
        let peakStartMinutes = self.peakStartHour * 60
        let peakEndMinutes = self.peakEndHour * 60
        let isInPeakWindow = nowMinutes >= peakStartMinutes && nowMinutes < peakEndMinutes

        if isWeekday && isInPeakWindow {
            let remaining = peakEndMinutes - nowMinutes
            return Status(
                isPeak: true,
                label: "Peak · ends in \(self.formatDuration(minutes: remaining))")
        }

        if isWeekday {
            if nowMinutes < peakStartMinutes {
                let until = peakStartMinutes - nowMinutes
                return Status(
                    isPeak: false,
                    label: "Off-peak · peak in \(self.formatDuration(minutes: until))")
            } else {
                let minutesLeftToday = 24 * 60 - nowMinutes
                let nextPeakMinutes: Int
                if weekday == 6 {
                    nextPeakMinutes = minutesLeftToday + 2 * 24 * 60 + peakStartMinutes
                } else {
                    nextPeakMinutes = minutesLeftToday + peakStartMinutes
                }
                return Status(
                    isPeak: false,
                    label: "Off-peak · peak in \(self.formatDuration(minutes: nextPeakMinutes))")
            }
        }

        let daysUntilMonday: Int
        if weekday == 7 {
            daysUntilMonday = 2
        } else {
            daysUntilMonday = 1
        }
        let minutesLeftToday = 24 * 60 - nowMinutes
        let totalMinutes = minutesLeftToday + (daysUntilMonday - 1) * 24 * 60 + peakStartMinutes
        return Status(
            isPeak: false,
            label: "Off-peak · peak in \(self.formatDuration(minutes: totalMinutes))")
    }

    private static func formatDuration(minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 {
            return "\(m)m"
        }
        if m == 0 {
            return "\(h)h"
        }
        return "\(h)h \(m)m"
    }

    private static func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = self.peakTimeZone
        return cal
    }
}
